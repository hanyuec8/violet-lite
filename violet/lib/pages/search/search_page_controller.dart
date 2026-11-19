// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';

import 'package:flare_flutter/flare_cache.dart';
import 'package:flare_flutter/flare_controls.dart';
import 'package:flare_flutter/provider/asset_flare.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/component/hitomi/hitomi_nozomi.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/hitomi/population.dart';
import 'package:violet/context/modal_bottom_sheet_context.dart';
import 'package:violet/database/query.dart';
import 'package:violet/log/log.dart';
import 'package:violet/pages/segment/filter_page_controller.dart';
import 'package:violet/script/script_manager.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/thread/semaphore.dart';

class SearchPageController extends GetxController {
  static SearchPageController? current;

  final FlareControls heroFlareControls = FlareControls();
  late AssetFlare asset;

  FilterController filterController = FilterController(
    heroKey: 'searchtype${ModalBottomSheetContext.getCount()}',
  );

  ScrollController? scrollController;
  Map<String, GlobalKey> itemKeys = <String, GlobalKey>{};

  final List<int> _scrollQueue = <int>[];
  double _itemHeight = 0.0;
  bool _scrollInProgress = false;
  bool _queryEnd = false;

  static const int defaultPageSize = 50;

  final Rx<SearchSortMode> searchSortMode = SearchSortMode.latest.obs;

  var isExtended = false.obs;
  var searchPageNum = 0.obs;
  var searchTotalResultCount = 0.obs;

  final Semaphore _querySem = Semaphore(maxCount: 1);
  (SearchResult?, String)? latestQuery;
  List<QueryResult> queryResult = [];
  List<QueryResult> filterResult = [];
  int baseCount = 0; // using for user custom page index
  bool isFilterUsed = false;

  var isHitomiFilterUsed = false.obs;
  var isHitomiFilterLoading = false.obs;
  List<QueryResult> hitomiFilterResult = [];
  int hitomiFilterPage = 1;
  int mainHybridPage = 1;

  final void Function({bool isAppend}) reloadForce;
  final bool isMainSearch;

  SearchPageController({
    required this.reloadForce,
    this.isMainSearch = true,
  });

  init(BuildContext context) {
    if (isMainSearch) {
      current = this;
    }
    asset = AssetFlare(
      bundle: rootBundle,
      name: 'assets/flare/search_close.flr',
    );
    cachedActor(asset);
  }

  @override
  void onClose() {
    if (current == this) current = null;
    super.onClose();
  }

  /// 설정에서 제외 태그가 변경되었을 때 현재 메모리에 로드된 작품들을 즉시 정제하고 리필합니다.
  void applyExcludedTagsFilter() {
    final curQuery = latestQuery?.$2 ?? '';
    queryResult.removeWhere((item) => Settings.isExcluded(item, currentQuery: curQuery));
    hitomiFilterResult.removeWhere((item) => Settings.isExcluded(item, currentQuery: curQuery));
    searchTotalResultCount.value = isHitomiFilterUsed.value
        ? hitomiFilterResult.length
        : queryResult.length;
    reloadForce();

    final count = isHitomiFilterUsed.value ? hitomiFilterResult.length : queryResult.length;
    if (count < 15 && !_queryEnd) {
      loadNextQuery();
    }
  }

  initScroll(BuildContext context) {
    if (scrollController == null) {
      scrollController = ScrollController();
      scrollController!.addListener(scrollPositionListener);
    }
  }

  /// 현재 검색 대상이 한국어(lang:korean)인지 판별합니다.
  bool isCurrentSearchKorean() {
    final query = latestQuery?.$2.trim().toLowerCase() ?? '';
    final match = RegExp(
      r'(?:^|[\s\(])(?:lang|language):([a-zA-Z가-힣]+)',
      caseSensitive: false,
    ).firstMatch(query);
    if (match != null) {
      final lang = match.group(1)!.toLowerCase();
      return lang == 'korean' || lang == '한국어';
    }
    // 쿼리에 타 언어가 명시되지 않은 경우 기본 검색 설정 언어 확인
    if (!query.contains('lang:') && !query.contains('language:')) {
      final selectedLangs = HybridLoader.getSelectedLanguages();
      return selectedLangs.length == 1 && selectedLangs.first == 'korean';
    }
    return false;
  }

  /// 현재 화면이 '마지막으로 본 작품' 기록 대상(메인 검색 + lang:korean + Hitomi 전용 필터, 태그 검색어 없음)인지 판별합니다.
  bool get canRecordLastViewedArticle {
    if (!isMainSearch || !isHitomiFilterUsed.value || !isCurrentSearchKorean()) {
      return false;
    }
    final raw = (latestQuery?.$2 ?? '').trim();
    if (raw.isEmpty) return true;
    final tokens = raw
        .replaceAll(RegExp(r'[\(\)]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    for (final tok in tokens) {
      final lower = tok.toLowerCase();
      if (lower.startsWith('lang:') || lower.startsWith('language:')) {
        continue;
      }
      return false;
    }
    return true;
  }

  /// 사용자가 메인 한국어 Hitomi 필터 피드에서 작품을 열어보았을 때,
  /// 기존 저장 위치 이상인 경우에만 마지막 본 작품과 위치를 기록합니다.
  void recordViewedArticle(QueryResult item) {
    if (!canRecordLastViewedArticle) return;
    final id = item.id();
    if (id <= 0) return;

    final list = getSearchList();
    final idx = list.indexWhere((e) => e.id() == id);
    if (idx < 0) return;

    final absolutePosition = baseCount + idx;
    final savedPosition = Settings.lastSearchPosition.value;
    if (savedPosition > 0 && absolutePosition < savedPosition) {
      return;
    }

    final itemPage = (item.result['_hybridPage'] as int?) ?? 1;
    Settings.lastSearchPosition.setValue(absolutePosition);
    Settings.lastSearchArticleId.setValue(id);
    Settings.lastSearchArticleTitle.setValue(item.title()?.toString() ?? '');
    Settings.lastSearchIsHitomiOnly.setValue(true);
    Settings.lastSearchMainPage.setValue(itemPage);
  }

  /// 현재 스크롤 위치(curI)의 작품을 마지막 본 위치로 저장합니다.
  void _savePositionAtIndex(int curI) {
    final list = getSearchList();
    if (curI < 0 || curI >= list.length) return;
    final item = list[curI];
    final id = item.id();
    if (id <= 0) return;

    final absolutePosition = baseCount + curI;
    final itemPage = (item.result['_hybridPage'] as int?) ?? 1;
    if (Settings.lastSearchPosition.value != absolutePosition) {
      Settings.lastSearchPosition.setValue(absolutePosition);
    }
    if (Settings.lastSearchArticleId.value != id) {
      Settings.lastSearchArticleId.setValue(id);
      Settings.lastSearchArticleTitle.setValue(item.title()?.toString() ?? '');
      Settings.lastSearchIsHitomiOnly.setValue(true);
    }
    if (Settings.lastSearchMainPage.value != itemPage) {
      Settings.lastSearchMainPage.setValue(itemPage);
    }
  }

  /// 사용자가 Item Jump 등에서 수동으로 현재 위치를 새 기준점으로 지정할 때 호출합니다.
  void pinCurrentPosition() {
    if (!canRecordLastViewedArticle) return;
    _savePositionAtIndex(searchPageNum.value);
    Fluttertoast.showToast(
      msg: '현재 위치(${searchPageNum.value + baseCount}번)를 마지막 본 위치로 저장했습니다.',
      toastLength: Toast.LENGTH_SHORT,
    );
  }

  scrollPositionListener() {
    //
    // scroll position
    //
    if (itemKeys.isNotEmpty && _itemHeight <= 0.1) {
      for (var key in itemKeys.entries) {
        // invisible article is not rendered yet
        // so we can find live elements
        if (key.value.currentContext != null) {
          final bottomPadding = [
            8,
            8,
            0,
            0,
            0,
          ][Settings.searchResultType.value.index];
          _itemHeight = key.value.currentContext!.size!.height + bottomPadding;
          break;
        }
      }
    }

    if (scrollController!.offset.isNaN) return;

    final itemPerRow = [3, 2, 1, 1, 1][Settings.searchResultType.value.index];
    const headerHeight = 76.0;
    final fallbackHeight = [200.0, 250.0, 130.0, 130.0, 220.0][Settings.searchResultType.value.index];
    final effectiveHeight = _itemHeight > 0.1 ? _itemHeight : fallbackHeight;
    final relativeOffset = (scrollController!.offset - headerHeight).clamp(0.0, double.infinity);
    final rawRow = relativeOffset / effectiveHeight;
    final maxIndex = (getSearchList().length - 1).clamp(0, 1000000);
    final curI = (rawRow.floor() * itemPerRow).clamp(0, maxIndex);

    if (curI != searchPageNum.value) {
      searchPageNum.value = curI;

      final isUserScrolling = scrollController?.hasClients == true &&
          scrollController!.position.userScrollDirection != ScrollDirection.idle;

      if (isUserScrolling && canRecordLastViewedArticle) {
        final absolutePosition = curI + baseCount;
        final savedPosition = Settings.lastSearchPosition.value;
        // 단순 단조 규칙: 기존 마지막 위치(savedPosition)보다 더 뒤로 내려갔을 때만 갱신하고,
        // 그 이전 위치에서는 어떤 스크롤/동작을 하더라도 기존 기억을 절대 덮어쓰지 않습니다.
        if (absolutePosition > savedPosition) {
          _savePositionAtIndex(curI);
        }
      }
    }

    //
    // scroll direction
    //
    var upScrolling =
        scrollController!.position.userScrollDirection ==
        ScrollDirection.forward;

    if (upScrolling) {
      _scrollQueue.add(-1);
    } else {
      _scrollQueue.add(1);
    }

    if (_scrollQueue.length > 64) {
      _scrollQueue.removeRange(0, _scrollQueue.length - 65);
    }

    var p = _scrollQueue.reduce((value, element) => value + element);

    if (p <= -32 && !isExtended.value) {
      isExtended.value = true;
    } else if (p >= 32 && isExtended.value) {
      isExtended.value = false;
    }

    //
    //  scroll lazy next query loading
    //
    if (_scrollInProgress || _queryEnd) return;
    final maxScroll = scrollController!.position.maxScrollExtent;
    final curOffset = scrollController!.offset;

    final isTrigger = isHitomiFilterUsed.value
        ? (maxScroll > 50 && curOffset > maxScroll * 0.2)
        : (maxScroll > 200 && curOffset > maxScroll * 0.6);

    if (isTrigger) {
      _scrollInProgress = true;
      Future.delayed(const Duration(milliseconds: 100), () async {
        try {
          await loadNextQuery();
        } catch (e) {
          print('loadNextQuery failed: $e');
        } finally {
          _scrollInProgress = false;
        }
      }).catchError((e) {
        _scrollInProgress = false;
      });
    }
  }

  resetItemHeight() => _itemHeight = 0.0;

  showErrorToast(String message) {
    FToast().showToast(
      toastDuration: const Duration(seconds: 10),
      child: Container(
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(),
          borderRadius: const BorderRadius.all(Radius.circular(8.0)),
        ),
        child: Text(message),
      ),
    );
  }

  loadNextQuery() async {
    final aquire = _querySem.acquire();
    if (!Settings.ignoreTimeout.value) {
      aquire.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          Logger.warning('[loadNextQuery] Query semaphore acquisition timed out');
          throw TimeoutException('Failed to acquire the query semaphore');
        },
      );
    }
    await aquire;

    if (isHitomiFilterUsed.value) {
      isHitomiFilterLoading.value = true;
    }

    try {
      if (_queryEnd) {
        return;
      }

      final query = latestQuery?.$2 ?? '';

      // 메인페이지와 동일한 고속 하이브리드 로더(0.3~0.5s)를 사용합니다.
      // Hitomi 단독 필터 상태:
      // - 현재 누적된 Hitomi 단독작이 12개 미만인 경우, 화면에 스크롤바가 생길 수 있도록 최소 12개 이상이 될 때까지 연속으로 빠르게 채웁니다.
      // - 이미 12개 이상 확보되어 스크롤이 가능한 상태라면 스크롤 시 1~2회 배치(0.3~0.5초)로 가볍게 새 작품들을 덧붙입니다.
      int attempts = 0;
      final targetCount = isHitomiFilterUsed.value
          ? (hitomiFilterResult.length < 12 ? 12 : hitomiFilterResult.length + 3)
          : 0;
      final maxAttempts = isHitomiFilterUsed.value
          ? (hitomiFilterResult.length < 12 ? 8 : 2)
          : 1;
      final hadExistingItems = isHitomiFilterUsed.value
          ? hitomiFilterResult.isNotEmpty
          : queryResult.isNotEmpty;

      while (attempts < maxAttempts) {
        attempts++;
        final fetchedPage = mainHybridPage;
        final hybridList = await HybridLoader.fetchMainHybridArticles(
          query: query,
          page: fetchedPage,
          pageSize: defaultPageSize,
          sortMode: searchSortMode.value,
        );
        mainHybridPage++;

        if (hybridList.isEmpty) {
          if (attempts < maxAttempts || (attempts < 3 && Settings.excludeTags.value.isNotEmpty)) {
            continue;
          }
          _queryEnd = true;
          break;
        }

        for (final item in hybridList) {
          item.result['_hybridPage'] = fetchedPage;
        }

        // 중복 방지 (기존 queryResult에 이미 존재하는 ID는 제외)
        final existingIds = queryResult.map((e) => e.id()).toSet();
        final newUnique = hybridList.where((e) => !existingIds.contains(e.id())).toList();
        if (newUnique.isEmpty) continue;

        queryResult.addAll(newUnique);

        // Hitomi 단독작 선별 및 hitomiFilterResult에 누적
        final newHitomiOnly = newUnique.where((e) => HybridLoader.isHitomiOnly(e)).toList();
        final existingHitomiIds = hitomiFilterResult.map((e) => e.id()).toSet();
        final uniqueHitomiOnly = newHitomiOnly.where((e) => !existingHitomiIds.contains(e.id())).toList();

        if (uniqueHitomiOnly.isNotEmpty) {
          hitomiFilterResult.addAll(uniqueHitomiOnly);
        }

        // 일반 모드이거나, Hitomi 단독 필터 모드에서 목표 수량(12개 이상)에 도달했으면 루프 종료
        if (!isHitomiFilterUsed.value || hitomiFilterResult.length >= targetCount) {
          break;
        }
      }

      if (filterController.isPopulationSort) {
        Population.sortByPopulation(queryResult);
        if (isHitomiFilterUsed.value) {
          Population.sortByPopulation(hitomiFilterResult);
        }
      }

      if (isFilterUsed) {
        final target = isHitomiFilterUsed.value ? hitomiFilterResult : queryResult;
        filterResult = filterController.applyFilter(target);
        searchTotalResultCount.value = baseCount + filterResult.length;
      } else {
        searchTotalResultCount.value = baseCount + (isHitomiFilterUsed.value
            ? hitomiFilterResult.length
            : queryResult.length);
      }

      reloadForce(isAppend: hadExistingItems);
      ScriptManager.refresh();
    } catch (e, st) {
      Logger.error(
        '[search-error] E: $e\n'
        '$st',
      );
      rethrow;
    } finally {
      isHitomiFilterLoading.value = false;
      _querySem.release();
    }
  }

  applyFilter() {
    final target = isHitomiFilterUsed.value ? hitomiFilterResult : queryResult;
    filterResult = filterController.applyFilter(target);
    isFilterUsed = true;
  }

  doSearch([int targetPosition = 0, int? startHybridPage]) async {
    _queryEnd = false;
    _scrollInProgress = false;
    itemKeys.clear();
    queryResult = [];
    hitomiFilterResult = [];

    // targetPosition(점프 위치)를 기반으로 시작 페이지 및 페이지 기준 오프셋 계산 (1-indexed)
    final startPage = startHybridPage ?? ((targetPosition ~/ defaultPageSize) + 1);
    final pageBaseOffset = startHybridPage != null
        ? targetPosition
        : (startPage - 1) * defaultPageSize;
    baseCount = pageBaseOffset;
    final targetIndexInPage = startHybridPage != null ? 0 : (targetPosition - pageBaseOffset);

    hitomiFilterPage = startPage;
    mainHybridPage = startPage;

    filterController = FilterController(
      heroKey: 'searchtype${ModalBottomSheetContext.getCount()}',
    );
    isFilterUsed = false;
    searchTotalResultCount.value = baseCount;
    searchPageNum.value = targetIndexInPage;

    if (scrollController?.hasClients ?? false) {
      scrollController?.jumpTo(0.0);
    }
    await loadNextQuery();

    if (targetIndexInPage > 0) {
      _scrollToItemIndex(targetIndexInPage);
    }
  }

  void _scrollToItemIndex(int index) {
    void performScroll() {
      if (scrollController == null || !scrollController!.hasClients) return;
      final itemPerRow = [3, 2, 1, 1, 1][Settings.searchResultType.value.index];
      final fallbackHeight = [200.0, 250.0, 130.0, 130.0, 220.0][Settings.searchResultType.value.index];
      final effectiveHeight = _itemHeight > 0.1 ? _itemHeight : fallbackHeight;
      const headerHeight = 76.0;
      final targetRow = index ~/ itemPerRow;
      final targetOffset = index == 0 ? 0.0 : (headerHeight + targetRow * effectiveHeight);
      final maxScroll = scrollController!.position.maxScrollExtent;
      final safeOffset = targetOffset.clamp(0.0, maxScroll > 0 ? maxScroll : targetOffset);
      scrollController!.jumpTo(safeOffset);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      performScroll();
      Future.delayed(const Duration(milliseconds: 100), performScroll);
    });
  }

  Future<void> jumpToLastArticle(BuildContext context) async {
    final targetId = Settings.lastSearchArticleId.value;
    final targetPos = Settings.lastSearchPosition.value;
    final wasHitomiOnly = Settings.lastSearchIsHitomiOnly.value;

    if (targetId <= 0 && targetPos <= 0) {
      Fluttertoast.showToast(msg: '마지막으로 본 작품 기록이 없습니다.');
      return;
    }

    // 1. 당시 Hitomi 전용 필터 상태 복원
    if (wasHitomiOnly && !isHitomiFilterUsed.value) {
      await toggleHitomiOnlyFilter(context);
    }

    // 2. 현재 메모리에 로드된 리스트에서 타깃 ID 탐색 (0ms 즉시 스크롤)
    final currentList = getSearchList();
    final existingIndex = targetId > 0
        ? currentList.indexWhere((e) => e.id() == targetId)
        : -1;

    if (existingIndex != -1) {
      searchPageNum.value = existingIndex;
      if (baseCount + existingIndex > Settings.lastSearchPosition.value) {
        Settings.lastSearchPosition.setValue(baseCount + existingIndex);
      }
      _scrollToItemIndex(existingIndex);
      Fluttertoast.showToast(
        msg: '마지막으로 본 작품(No. $targetId) 위치로 이동했습니다.',
        toastLength: Toast.LENGTH_SHORT,
      );
      return;
    }

    // 3. 아직 로드되지 않았거나 다른 페이지인 경우: 스마트 점프 및 신작 오차 자동 보정
    Fluttertoast.showToast(
      msg: '마지막으로 본 작품(No. $targetId)을 찾는 중...',
      toastLength: Toast.LENGTH_SHORT,
    );

    final savedMainPage = Settings.lastSearchMainPage.value;
    await doSearch(
      targetPos,
      (wasHitomiOnly && savedMainPage > 1) ? savedMainPage : null,
    );

    // 4. doSearch 후 타깃 작품 위치 탐색
    var foundIndex = targetId > 0
        ? getSearchList().indexWhere((e) => e.id() == targetId)
        : -1;

    // 만약 새 작품이 유입되어 바로 안 보인다면, 다음 배치(최대 3회)를 추가 로드하여 탐색
    int attempts = 0;
    while (foundIndex == -1 && attempts < 3 && !_queryEnd) {
      attempts++;
      await loadNextQuery();
      foundIndex = targetId > 0
          ? getSearchList().indexWhere((e) => e.id() == targetId)
          : -1;
    }

    if (foundIndex != -1) {
      if (wasHitomiOnly && Settings.lastSearchMainPage.value > 1) {
        baseCount = (targetPos - foundIndex).clamp(0, 1000000);
        searchTotalResultCount.value = baseCount + getSearchList().length;
      }
      searchPageNum.value = foundIndex;
      if (baseCount + foundIndex > Settings.lastSearchPosition.value) {
        Settings.lastSearchPosition.setValue(baseCount + foundIndex);
      }
      _scrollToItemIndex(foundIndex);
      Fluttertoast.showToast(
        msg: '마지막으로 본 작품(No. $targetId) 위치를 찾아 이동했습니다.',
        toastLength: Toast.LENGTH_SHORT,
      );
    } else {
      // 작품 ID를 직접 찾지 못했더라도 저장된 인덱스 위치 근처에 안전하게 도착
      final targetIndexInPage = targetPos - baseCount;
      if (targetIndexInPage > 0 && targetIndexInPage < getSearchList().length) {
        _scrollToItemIndex(targetIndexInPage);
      }
      Fluttertoast.showToast(
        msg: '마지막으로 본 위치($targetPos 번 부근)로 이동했습니다.',
        toastLength: Toast.LENGTH_SHORT,
      );
    }
  }

  List<QueryResult> getSearchList() {
    if (isFilterUsed) return filterResult;
    if (isHitomiFilterUsed.value) return hitomiFilterResult;
    return queryResult;
  }

  Future<void> toggleHitomiOnlyFilter(BuildContext context) async {
    if (isHitomiFilterLoading.value) return;

    if (isHitomiFilterUsed.value) {
      // Hitomi 필터 해제 -> 메인 전체 작품 목록으로 0ms 즉시 복원
      isHitomiFilterUsed.value = false;
      if (isFilterUsed) {
        filterResult = filterController.applyFilter(queryResult);
        searchTotalResultCount.value = baseCount + filterResult.length;
      } else {
        searchTotalResultCount.value = baseCount + queryResult.length;
      }
      reloadForce();
      Fluttertoast.showToast(
        msg: 'Hitomi 전용 필터 해제 (전체 ${queryResult.length}건)',
        toastLength: Toast.LENGTH_SHORT,
      );
      return;
    }

    // Hitomi 전용 필터 활성화
    isHitomiFilterUsed.value = true;

    // 1) 0ms 즉각 노출: 지금까지 queryResult에 로드된 작품들 중 Hitomi 단독작을 즉시 추출
    final cachedHitomi = queryResult.where((item) => HybridLoader.isHitomiOnly(item)).toList();
    hitomiFilterResult = List<QueryResult>.from(cachedHitomi);

    if (isFilterUsed) {
      filterResult = filterController.applyFilter(hitomiFilterResult);
      searchTotalResultCount.value = baseCount + filterResult.length;
    } else {
      searchTotalResultCount.value = baseCount + hitomiFilterResult.length;
    }
    reloadForce();

    // 2) 만약 기존에 캐시된 Hitomi 단독작이 스크롤 가능 수량(12개) 미만이라면
    // 화면을 멈추지 않고 비동기로 최소 12개 이상이 채워질 때까지 연속 요청
    if (hitomiFilterResult.length < 12 && !_queryEnd) {
      unawaited(loadNextQuery());
    }

    if (hitomiFilterResult.isNotEmpty) {
      Fluttertoast.showToast(
        msg: 'Hitomi 단독 작품 ${hitomiFilterResult.length}건 표시 (스크롤 시 계속 로딩)',
        toastLength: Toast.LENGTH_SHORT,
      );
    } else {
      Fluttertoast.showToast(
        msg: 'Hitomi 단독 작품을 찾는 중...',
        toastLength: Toast.LENGTH_SHORT,
      );
    }
  }
}
