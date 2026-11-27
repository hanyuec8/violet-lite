// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/component/hitomi/hitomi_nozomi.dart';
import 'package:violet/component/hitomi/hitomi_parser.dart';
import 'package:violet/component/hitomi/population.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/database.dart';
import 'package:violet/database/expunged_database.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/bookmark.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/log/log.dart';
import 'package:violet/network/wrapper.dart' as http;
import 'package:violet/script/script_manager.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/grouping.dart' as rust_grouping;
import 'package:violet/src/rust/api/nozomi.dart' as rust_nozomi;
import 'package:violet/src/rust/frb_generated.dart';

/// 고정 용량 초과 시 가장 오래된 항목을 자동 제거하는 경량 LRU 맵
class _LruMap<K, V> {
  final int capacity;
  final Map<K, V> _map = <K, V>{};

  _LruMap({this.capacity = 2000});

  V? operator [](K key) {
    final value = _map.remove(key);
    if (value != null) {
      _map[key] = value;
    }
    return value;
  }

  void operator []=(K key, V value) {
    if (_map.containsKey(key)) {
      _map.remove(key);
    } else if (_map.length >= capacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = value;
  }

  bool containsKey(K key) => _map.containsKey(key);
  int get length => _map.length;
  void clear() => _map.clear();
}

/// Violet (E-Hentai / 로컬 DB) + Hitomi (Nozomi Range Request)
/// 하이브리드 작품 로더
class HybridLoader {
  /// 사용자가 설정한 검색 대상 언어 목록 (비어있으면 전체)
  static List<String> getSelectedLanguages() {
    final inc = Settings.includeTags.value.toLowerCase();
    final langs = <String>[];
    if (inc.contains('korean')) langs.add('korean');
    if (inc.contains('japanese')) langs.add('japanese');
    if (inc.contains('english')) langs.add('english');
    if (inc.contains('chinese')) langs.add('chinese');
    return langs;
  }

  /// 앱 실행 중 유지되는 인메모리 세션 캐시 (LRU 최대 2,000건 제한으로 OOM 방지)
  /// 품번(Id) -> 뱃지 소스 ('common' | 'hitomi' | 'ehentai' | 'hitomi_only')
  static final _LruMap<int, String> _sessionBadgeCache =
      _LruMap<int, String>(capacity: 2000);

  /// 품번(Id) -> Hitomi 기본 메타데이터 QueryResult
  static final _LruMap<int, QueryResult> _sessionMetadataCache =
      _LruMap<int, QueryResult>(capacity: 2000);

  /// 작가, 그룹, 시리즈, 캐릭터, 업로더의 최신 작품 목록을
  /// Hitomi Nozomi와 E-Hentai에서 동시에 비동기 수집하여 중복 제거 후 반환합니다.
  static Future<List<QueryResult>> fetchArtistArticlesHybrid({
    required String name,
    required String type,
    int page = 1,
    int pageSize = 60,
    String? language,
  }) async {
    final selectedLangs = getSelectedLanguages();
    String targetLang = language ?? (selectedLangs.length == 1 ? selectedLangs.first : 'all');

    String getNozomiUrl(String lang) {
      switch (type.toLowerCase()) {
        case 'artist':
          return HitomiNozomi.getArtistIndexUrl(name, lang);
        case 'group':
          return HitomiNozomi.getGroupIndexUrl(name, lang);
        case 'series':
          return HitomiNozomi.getSeriesIndexUrl(name, lang);
        case 'character':
          return HitomiNozomi.getCharacterIndexUrl(name, lang);
        case 'uploader':
          return HitomiNozomi.getUploaderIndexUrl(name, lang);
        case 'tag':
          return HitomiNozomi.getTagIndexUrl(name, lang);
        default:
          return HitomiNozomi.getArtistIndexUrl(name, lang);
      }
    }

    Future<List<QueryResult>> fetchWithLang(String lang) async {
      final results = <QueryResult>[];
      final seenIds = <int>{};

      // 1) 로컬 SQLite DB + Expunged DB 스트림: 0.05초 만에 즉시 반환
      final localDbFuture = Future<List<QueryResult>>(() async {
        try {
          final db = await DataBaseManager.getInstance();
          final hasMainDb = db.db != null && db.db!.isOpen;
          final expungedDb = await ExpungedDatabaseManager.getInstance();
          final hasExpungedDb = expungedDb != null && expungedDb.isOpen;

          if (!hasMainDb && !hasExpungedDb) return [];

          final safeName = name.replaceAll("'", "''").replaceAll(' ', '_');
          final token = '${type.toLowerCase()}:$safeName';
          final langToken = lang != 'all' ? 'language:$lang' : '';
          final translated = translate2query('$token $langToken'.trim(), filter: false);
          final offset = (page - 1) * pageSize;
          final sql = '$translated ORDER BY Id DESC LIMIT $pageSize OFFSET $offset';

          final results = <QueryResult>[];
          if (hasMainDb) {
            try {
              final rows = await db.query(sql);
              results.addAll(rows.map((r) {
                final map = Map<String, dynamic>.from(r);
                map['source'] = 'common';
                map['is_common'] = true;
                return QueryResult(result: map);
              }));
            } catch (e, st) {
              Logger.error('[HybridLoader-Artist-Db] E: $e\n$st');
            }
          }
          if (hasExpungedDb) {
            try {
              final expRows = await expungedDb.rawQuery(sql);
              for (final r in expRows) {
                final map = Map<String, dynamic>.from(r);
                map['source'] = 'common';
                map['is_common'] = true;
                map['is_expunged'] = true;
                results.add(QueryResult(result: map));
              }
            } catch (e, st) {
              Logger.error('[HybridLoader-Artist-ExpungedDb] E: $e\n$st');
            }
          }
          return results;
        } catch (e, st) {
          Logger.error('[HybridLoader-Artist-Db] E: $e\n$st');
          return [];
        }
      }).timeout(
        const Duration(seconds: 4),
        onTimeout: () => <QueryResult>[],
      );

      // 2) Hitomi Nozomi Range Request 스트림
      final hitomiFuture = Future<List<QueryResult>>(() async {
        final hitomiList = <QueryResult>[];
        try {
          List<int> ids = [];
          if (lang != 'all') {
            ids = await HitomiNozomi.fetchGalleryIds(
              getNozomiUrl(lang),
              page,
              pageSize: pageSize,
            );
          } else {
            ids = await HitomiNozomi.fetchGalleryIds(
              getNozomiUrl('all'),
              page,
              pageSize: pageSize,
            );
          }
          if (ids.isEmpty) return [];

          // 1단계: 캐시(메모리 + user.db ArticleCache 디스크) 일괄 선조회 (0.01초)
          final cachedMap = await getCachedMetadataBatch(ids);
          final missingIds = <int>[];
          for (final id in ids) {
            if (cachedMap.containsKey(id)) {
              hitomiList.add(cachedMap[id]!);
            } else {
              missingIds.add(id);
            }
          }

          // 2단계: 캐시에 없는 항목만 경량 네트워크 조회 (_idQueryHitomiFast)
          if (missingIds.isNotEmpty) {
            const chunkSize = 20;
            for (var i = 0; i < missingIds.length; i += chunkSize) {
              final end = (i + chunkSize < missingIds.length) ? i + chunkSize : missingIds.length;
              final chunk = missingIds.sublist(i, end);
              final chunkFutures = chunk.map((id) => _idQueryHitomiFast(id));
              hitomiList.addAll(await Future.wait(chunkFutures));
            }
          }
          for (final qr in hitomiList) {
            if (qr.result['is_common'] != true &&
                qr.result['source'] != 'common' &&
                qr.result['source'] != 'ehentai' &&
                qr.result['source'] != 'violet') {
              qr.result['source'] ??= 'hitomi';
            }
          }
          return hitomiList;
        } catch (e, st) {
          Logger.error('[HybridLoader-Artist-Hitomi] E: $e\n$st');
          return hitomiList;
        }
      }).timeout(
        const Duration(seconds: 12),
        onTimeout: () => <QueryResult>[],
      );

      // 3) E-Hentai 검색
      var ehSucceeded = false;
      final ehentaiFuture = Future<List<QueryResult>>(() async {
        try {
          final langPrefix = lang != 'all' ? 'language:$lang ' : '';
          final queryTag = '$langPrefix${type.toLowerCase()}:"$name"';
          final ehQuery = formatEHentaiQuery(queryTag, lang);
          final offset = (page - 1) * pageSize;
          final ehList = await HentaiManager.searchEHentai(ehQuery, offset);
          ehSucceeded = true;
          for (final qr in ehList) {
            qr.result['source'] = 'ehentai';
          }
          return ehList;
        } catch (e, st) {
          Logger.error('[HybridLoader-Artist-EHentai] E: $e\n$st');
          return [];
        }
      }).timeout(
        const Duration(seconds: 10),
        onTimeout: () => <QueryResult>[],
      );

      // 3개 소스를 병렬로 동시 대기 (Triple Hybrid)
      final responses = await Future.wait([localDbFuture, hitomiFuture, ehentaiFuture])
          .timeout(
            const Duration(seconds: 14),
            onTimeout: () => [<QueryResult>[], <QueryResult>[], <QueryResult>[]],
          );
      final localDbResults = responses[0];
      final hitomiResults = responses[1];
      final ehResults = responses[2];

      void addResult(QueryResult qr) {
        final id = qr.id();

        // 언어 필터링 (한국어 등 지정 언어가 설정된 경우)
        if (lang != 'all') {
          final qrLang = (qr.language() ?? '').toString().toLowerCase();
          final tags = (qr.tags() ?? '').toString().toLowerCase();
          final qrTitle = (qr.title() ?? '').toString().toLowerCase();

          final matchLang = qrLang.contains(lang) ||
              tags.contains(lang) ||
              (lang == 'korean' &&
                  (qrLang == 'korean' ||
                      tags.contains('korean') ||
                      qrTitle.contains('[한국어]') ||
                      qrTitle.contains('(한국어)')));

          if (!matchLang) {
            return;
          }
        }

        if (Settings.isExcluded(qr)) return;

        if (seenIds.contains(id)) return;
        seenIds.add(id);
        results.add(qr);
      }

      // 로컬 DB 결과 우선 반영 (Violet 공식 DB 100% 공통 작품)
      for (final item in localDbResults) {
        addResult(item);
      }

      // Hitomi 최신 결과 반영 (로컬 DB와 대조 및 승격)
      for (final item in hitomiResults) {
        final id = item.id();
        final existing = results.where((r) => r.id() == id).firstOrNull;
        if (existing != null) {
          existing.result['source'] = 'common';
          existing.result['is_common'] = true;
          _sessionBadgeCache[id] = 'common';
        } else {
          // 로컬 DB에 동일 언어 및 제목이 일치하는 항목이 있으면 common으로 승격
          final existingByTitle = results.where((r) =>
              isLanguageMatched(r, item) &&
              isTitleMatched(r.title() ?? '', item.title() ?? '')).firstOrNull;
          if (existingByTitle != null) {
            existingByTitle.result['source'] = 'common';
            existingByTitle.result['is_common'] = true;
            _sessionBadgeCache[existingByTitle.id()] = 'common';
          }
          // 중요: Hitomi의 고유 ID 작품은 절대로 버리지 않고 리스트에 독립 추가
          addResult(item);
        }
      }

      // E-Hentai 결과 추가 병합 및 공통 작품 승격
      final ehIds = <int>{};
      final ehTitles = <String>{};
      for (final item in ehResults) {
        final id = item.id();
        final itemTitle = item.title() ?? '';
        ehIds.add(id);
        if (itemTitle.isNotEmpty) ehTitles.add(itemTitle);
        final existing = results.where((r) {
          if (r.id() == id) return true;
          return isLanguageMatched(r, item) && isTitleMatched(r.title() ?? '', itemTitle);
        }).firstOrNull;

        if (existing != null) {
          existing.result['source'] = 'common';
          existing.result['is_common'] = true;
          if (item.ehash() != null) existing.result['EHash'] = item.ehash();
          _sessionBadgeCache[existing.id()] = 'common';
        } else {
          addResult(item);
        }
      }

      final hitomiItems = results.where((m) => m.result['source'] == 'hitomi').toList();
      if (hitomiItems.isNotEmpty) {
        await verifyAndTagHitomiArticles(
          hitomiItems,
          knownEhIds: ehIds,
          knownEhTitles: ehTitles,
          allowMarkHitomiOnly: ehSucceeded,
        );
      }

      // ID 기준 최신순 정렬
      results.sort((a, b) => b.id().compareTo(a.id()));
      return results;
    }

    // 사용자가 지정한 targetLang으로 검색 (지정 언어 부재 시 타 언어를 임의로 섞지 않음)
    var finalResults = await fetchWithLang(targetLang);

    return finalResults;
  }

  static bool get _useRustGrouping {
    try {
      return RustLib.instance.initialized;
    } catch (_) {
      return false;
    }
  }

  /// 제목 정규화 유틸리티 (특수문자, 괄호, 이벤트명, 언어태그 제거)
  static String normalizeTitle(String raw) {
    if (_useRustGrouping) {
      return rust_grouping.normalizeTitleSync(raw: raw);
    }
    var s = raw
        .replaceAll(RegExp(r'\[.*?\]'), ' ')
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll(RegExp(r'\{.*?\}'), ' ')
        .toLowerCase();
    // 한글, 영문, 일본어(가나/한자), 숫자만 남겨 정밀 비교
    return s.replaceAll(RegExp(r'[^0-9a-zA-Z가-힣\u3040-\u30ff\u4e00-\u9faf]'), '');
  }

  /// 제목에서 서브타이틀(|, /, :) 등을 고려하여 정규화된 토큰 목록을 추출합니다.
  static List<String> extractTitleTokens(String raw) {
    if (raw.trim().isEmpty) return [];
    if (_useRustGrouping) {
      return rust_grouping.extractTitleTokensSync(raw: raw);
    }
    final results = <String>{};

    // 1. 파이프(|), 슬래시(/), 하이픈(-) 등 서브타이틀 분리자로 분할
    final parts = raw.split(RegExp(r'\||\/|\s-\s'));
    for (final part in parts) {
      final norm = normalizeTitle(part);
      if (norm.length >= 3) {
        results.add(norm);
      }
    }

    // 2. 전체 문자열 정규화
    final fullNorm = normalizeTitle(raw);
    if (fullNorm.length >= 3) {
      results.add(fullNorm);
    }

    return results.toList();
  }

  /// 두 제목이 동일하거나 동일 작품의 변형인지 정밀 대조합니다.
  static bool isTitleMatched(String rawA, String rawB) {
    if (rawA.isEmpty || rawB.isEmpty) return false;
    if (_useRustGrouping) {
      return rust_grouping.isTitleMatchedSync(rawA: rawA, rawB: rawB);
    }
    final fullA = normalizeTitle(rawA);
    final fullB = normalizeTitle(rawB);
    if (fullA.length >= 3 && fullA == fullB) return true;

    final tokensA = extractTitleTokens(rawA);
    final tokensB = extractTitleTokens(rawB);

    if (fullA.length >= 5 && tokensB.contains(fullA)) return true;
    if (fullB.length >= 5 && tokensA.contains(fullB)) return true;
    return false;
  }

  /// 두 작품의 언어가 일치하는지 판별합니다.
  /// 둘 중 하나가 언어 미지정이거나 N/A인 경우 허용하며, 명확한 언어가 서로 다르면 false를 반환합니다.
  static bool isLanguageMatched(QueryResult a, QueryResult b) {
    final langA = normalizeLanguage(a.language()?.toString() ?? '');
    final langB = normalizeLanguage(b.language()?.toString() ?? '');
    if (langA.isEmpty || langA == 'n/a' || langB.isEmpty || langB == 'n/a') {
      return true;
    }
    return langA == langB;
  }

  /// 언어 문자열을 표준화 (korean, japanese, english, chinese, spanish 등)
  static String normalizeLanguage(String raw) {
    final l = raw.toLowerCase().trim();
    if (l.contains('korean') || l.contains('한국어')) return 'korean';
    if (l.contains('japanese') || l.contains('일본어') || l.contains('日本語')) return 'japanese';
    if (l.contains('english') || l.contains('영어')) return 'english';
    if (l.contains('chinese') || l.contains('중국어') || l.contains('中文')) return 'chinese';
    if (l.contains('spanish') || l.contains('español') || l.contains('스페인어')) return 'spanish';
    return l;
  }

  /// 사용자가 입력한 다양한 검색어(태그, 작가, 그룹, 시리즈, 캐릭터, 업로더 또는 성별 없는 태그)를
  /// Hitomi Nozomi 인덱스 URL로 스마트하게 변환하여 Gallery ID 목록을 Range Header로 로딩합니다.
  /// random 검색 시 최신작뿐만 아니라 10년 전 고전부터 최근까지 전 기간(0~100%)에서
  /// 균등 분산 무작위 샘플링으로 Gallery ID 목록을 수집합니다.
  static Future<List<int>> fetchRandomGalleryIdsForQuery({
    required String query,
    required String targetLang,
    required List<String> selectedLangs,
    required int count,
    required double? seed,
    required int page,
  }) async {
    try {
      String targetUrl;
      final cleanQuery = query.trim();
      if (cleanQuery.isEmpty) {
        if (targetLang != 'all') {
          targetUrl = HitomiNozomi.getLanguageIndexUrl(targetLang);
        } else if (selectedLangs.isNotEmpty && !selectedLangs.contains('all')) {
          targetUrl = HitomiNozomi.getLanguageIndexUrl(selectedLangs.first);
        } else {
          targetUrl = HitomiNozomi.getIndexAllUrl();
        }
      } else {
        final tokens = cleanQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
        final langToken = tokens.where((t) => t.startsWith('lang:') || t.startsWith('language:')).firstOrNull;
        final nonLang = tokens.where((t) => !t.startsWith('lang:') && !t.startsWith('language:')).toList();
        if (nonLang.isEmpty && langToken != null) {
          final l = langToken.split(':').last;
          targetUrl = HitomiNozomi.getLanguageIndexUrl(l);
        } else {
          return await fetchGalleryIdsForQuery(
            query: cleanQuery,
            page: page,
            pageSize: count,
            targetLang: targetLang,
          );
        }
      }

      final totalCount = await HitomiNozomi.getTotalCount(targetUrl);
      if (totalCount == null || totalCount <= count) {
        return await fetchGalleryIdsForQuery(
          query: cleanQuery,
          page: page,
          pageSize: count,
          targetLang: targetLang,
        );
      }

      const numSegments = 5;
      final perSegment = (count / numSegments).ceil();
      final segmentSize = totalCount ~/ numSegments;
      final s = seed ?? (DateTime.now().microsecondsSinceEpoch % 10000) / 1000.0 + 1.0;

      final futures = <Future<List<int>>>[];
      for (int i = 0; i < numSegments; i++) {
        final segStart = i * segmentSize;
        final maxOffsetInSeg = (segmentSize - perSegment).clamp(1, segmentSize);
        final segOffset = ((s * 10000 + page * 499 + i * 173).toInt() % maxOffsetInSeg);
        final absOffset = (segStart + segOffset).clamp(0, totalCount - perSegment);
        futures.add(HitomiNozomi.fetchGalleryIdsByOffset(targetUrl, absOffset, perSegment));
      }

      final results = await Future.wait(futures);
      final mergedIds = <int>{};
      for (final list in results) {
        mergedIds.addAll(list);
      }

      return mergedIds.take(count).toList();
    } catch (e, st) {
      Logger.error('[HybridLoader-RandomFetch] E: $e\n$st');
      return await fetchGalleryIdsForQuery(
        query: query,
        page: page,
        pageSize: count,
        targetLang: targetLang,
      );
    }
  }

  static bool _isFilterOrNegativeToken(String rawToken) {
    final t = rawToken.replaceAll(RegExp(r'[\(\)]'), '').trim().toLowerCase();
    if (t.isEmpty) return false;
    if (t.startsWith('-')) return true;
    if (RegExp(r'^id(?:!=|>=|<=|==|>|<|=)\d+$').hasMatch(t)) return true;
    if (RegExp(r'^id:\d+(?:~|\.\.|\-)\d+$').hasMatch(t)) return true;
    if (RegExp(r'^page(?:>=|<=|==|>|<|=|:)').hasMatch(t)) return true;
    if (RegExp(r'^(?:date|published)(?:>=|<=|==|>|<|=|:)').hasMatch(t)) {
      return true;
    }
    return false;
  }

  static bool _isIdExcludedByQueryTokens(int id, List<String> tokens) {
    for (final raw in tokens) {
      final t = raw.replaceAll(RegExp(r'[\(\)]'), '').trim().toLowerCase();
      if (t.isEmpty) continue;
      if (t.startsWith('-')) {
        final core = t.substring(1).trim();
        if (Settings.isIdExcludeRule(core) && Settings.matchesIdRule(id, core)) {
          return true;
        }
      } else if (t.startsWith('id!=')) {
        final val = int.tryParse(t.substring(4).trim());
        if (val != null && id == val) return true;
      }
    }
    return false;
  }

  static Future<List<int>> fetchGalleryIdsForQuery({
    required String query,
    required int page,
    int pageSize = 30,
    required String targetLang,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      if (targetLang != 'all') {
        final ids = await HitomiNozomi.fetchGalleryIds(
          HitomiNozomi.getLanguageIndexUrl(targetLang),
          page,
          pageSize: pageSize,
        );
        if (ids.isNotEmpty) return ids;
      }
      return await HitomiNozomi.fetchGalleryIds(
        HitomiNozomi.getIndexAllUrl(),
        page,
        pageSize: pageSize,
      );
    }

    // 복합 쿼리의 경우 토큰 추출 및 언어 토큰 감지
    final tokens =
        cleanQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    String effectiveLang = targetLang;
    String? explicitLang;
    final nonLangTokens = <String>[];

    for (final token in tokens) {
      final lower = token.toLowerCase();
      if (lower.startsWith('lang:')) {
        explicitLang = lower.substring(5).trim();
      } else if (lower.startsWith('language:')) {
        explicitLang = lower.substring(9).trim();
      } else {
        nonLangTokens.add(token);
      }
    }

    if (explicitLang != null && explicitLang.isNotEmpty) {
      effectiveLang = explicitLang;
    }

    final positiveNozomiTokens = nonLangTokens
        .where((t) => !_isFilterOrNegativeToken(t))
        .toList();

    // 언어 토큰만 있거나 부정/필터 토큰만 있는 경우 기본 언어/전체 인덱스 사용
    if (positiveNozomiTokens.isEmpty) {
      if (effectiveLang != 'all') {
        final ids = await HitomiNozomi.fetchGalleryIds(
          HitomiNozomi.getLanguageIndexUrl(effectiveLang),
          page,
          pageSize: pageSize,
        );
        if (ids.isNotEmpty) return ids;
        if (explicitLang != null && explicitLang.isNotEmpty) return [];
      }
      return await HitomiNozomi.fetchGalleryIds(
        HitomiNozomi.getIndexAllUrl(),
        page,
        pageSize: pageSize,
      );
    }

    // 1) 다중 태그(복합 쿼리)인 경우: 각 긍정 태그별 상위 ID를 병렬 수집 후 Rust SIMD 교집합(Intersection) 산출
    if (positiveNozomiTokens.length > 1) {
      const multiTagFetchCount = 10000;
      final tokenResults = await Future.wait(
        positiveNozomiTokens.map((tok) => _fetchIdsForSingleTerm(
              term: tok,
              effectiveLang: effectiveLang,
              offset: 0,
              count: multiTagFetchCount,
              explicitLang: explicitLang,
            )),
      );

      // 어떤 태그의 결과가 0건이면 교집합도 0건
      if (tokenResults.any((list) => list.isEmpty)) {
        return [];
      }

      List<int> sortedIntersection;
      try {
        final rustLists = tokenResults
            .map((list) => Uint32List.fromList(list))
            .toList();
        sortedIntersection = rust_nozomi.intersectNozomiIds(lists: rustLists);
      } catch (_) {
        // Rust FFI 오류 시 Dart Set 교집합 폴백
        Set<int> intersection = tokenResults.first.toSet();
        for (int i = 1; i < tokenResults.length; i++) {
          intersection = intersection.intersection(tokenResults[i].toSet());
          if (intersection.isEmpty) return [];
        }
        sortedIntersection = intersection.toList()
          ..sort((a, b) => b.compareTo(a));
      }

      final startIdx = (page - 1) * pageSize;
      if (startIdx >= sortedIntersection.length) {
        return [];
      }
      final endIdx = (startIdx + pageSize < sortedIntersection.length)
          ? startIdx + pageSize
          : sortedIntersection.length;
      return sortedIntersection.sublist(startIdx, endIdx);
    }

    // 2) 단일 태그(단독 쿼리)인 경우: 단일 페이징 고속 조회
    final primaryTerm = positiveNozomiTokens.first;

    return await _fetchIdsForSingleTerm(
      term: primaryTerm,
      effectiveLang: effectiveLang,
      offset: (page - 1) * pageSize,
      count: pageSize,
      explicitLang: explicitLang,
    );
  }

  /// 단일 검색어(태그, 작가, 그룹, 시리즈 등)에 대해 Nozomi ID 목록을 가져옵니다.
  static Future<List<int>> _fetchIdsForSingleTerm({
    required String term,
    required String effectiveLang,
    required int offset,
    required int count,
    String? explicitLang,
  }) async {
    var primaryTerm = term.trim();
    if (primaryTerm.toLowerCase().startsWith('tag:')) {
      primaryTerm = primaryTerm.substring(4).trim();
    }

    // 순수 숫자 또는 id:12345 인 경우 품번 ID 직접 반환 (부정형 제외)
    final numericId = !primaryTerm.startsWith('-')
        ? (int.tryParse(primaryTerm) ??
            (primaryTerm.toLowerCase().startsWith('id:')
                ? int.tryParse(primaryTerm.substring(3).trim())
                : null))
        : null;
    if (numericId != null && numericId > 0) {
      return offset == 0 ? [numericId] : <int>[];
    }

    final colonIdx = primaryTerm.indexOf(':');
    if (colonIdx != -1) {
      final prefix = primaryTerm.substring(0, colonIdx).trim().toLowerCase();
      final val = primaryTerm.substring(colonIdx + 1).trim();
      switch (prefix) {
        case 'lang':
        case 'language':
          return await HitomiNozomi.fetchGalleryIdsByOffset(
            HitomiNozomi.getLanguageIndexUrl(val.toLowerCase()),
            offset,
            count,
          );
        case 'artist':
          if (effectiveLang != 'all') {
            final ids = await HitomiNozomi.fetchGalleryIdsByOffset(
              HitomiNozomi.getArtistIndexUrl(val, effectiveLang),
              offset,
              count,
            );
            if (ids.isNotEmpty) return ids;
            if (explicitLang != null && explicitLang.isNotEmpty) return [];
          }
          return await HitomiNozomi.fetchGalleryIdsByOffset(
            HitomiNozomi.getArtistIndexUrl(val, 'all'),
            offset,
            count,
          );
        case 'group':
          if (effectiveLang != 'all') {
            final ids = await HitomiNozomi.fetchGalleryIdsByOffset(
              HitomiNozomi.getGroupIndexUrl(val, effectiveLang),
              offset,
              count,
            );
            if (ids.isNotEmpty) return ids;
            if (explicitLang != null && explicitLang.isNotEmpty) return [];
          }
          return await HitomiNozomi.fetchGalleryIdsByOffset(
            HitomiNozomi.getGroupIndexUrl(val, 'all'),
            offset,
            count,
          );
        case 'series':
          if (effectiveLang != 'all') {
            final ids = await HitomiNozomi.fetchGalleryIdsByOffset(
              HitomiNozomi.getSeriesIndexUrl(val, effectiveLang),
              offset,
              count,
            );
            if (ids.isNotEmpty) return ids;
            if (explicitLang != null && explicitLang.isNotEmpty) return [];
          }
          return await HitomiNozomi.fetchGalleryIdsByOffset(
            HitomiNozomi.getSeriesIndexUrl(val, 'all'),
            offset,
            count,
          );
        case 'character':
          if (effectiveLang != 'all') {
            final ids = await HitomiNozomi.fetchGalleryIdsByOffset(
              HitomiNozomi.getCharacterIndexUrl(val, effectiveLang),
              offset,
              count,
            );
            if (ids.isNotEmpty) return ids;
            if (explicitLang != null && explicitLang.isNotEmpty) return [];
          }
          return await HitomiNozomi.fetchGalleryIdsByOffset(
            HitomiNozomi.getCharacterIndexUrl(val, 'all'),
            offset,
            count,
          );
        case 'uploader':
          if (effectiveLang != 'all') {
            final ids = await HitomiNozomi.fetchGalleryIdsByOffset(
              HitomiNozomi.getUploaderIndexUrl(val, effectiveLang),
              offset,
              count,
            );
            if (ids.isNotEmpty) return ids;
            if (explicitLang != null && explicitLang.isNotEmpty) return [];
          }
          return await HitomiNozomi.fetchGalleryIdsByOffset(
            HitomiNozomi.getUploaderIndexUrl(val, 'all'),
            offset,
            count,
          );
        case 'tag':
        case 'female':
        case 'male':
          if (effectiveLang != 'all') {
            final ids = await HitomiNozomi.fetchTagGalleryIdsByOffset(
              primaryTerm,
              offset,
              count,
              language: effectiveLang,
            );
            if (ids.isNotEmpty) return ids;
            if (explicitLang != null && explicitLang.isNotEmpty) return [];
          }
          return await HitomiNozomi.fetchTagGalleryIdsByOffset(
            primaryTerm,
            offset,
            count,
            language: 'all',
          );
        default:
          break;
      }
    }

    // 콜론이 없는 일반 단어: 1차 기본 언어 태그 조회 후, 부족하면 전체 태그·작가·시리즈·제목 B-Tree 병렬 조회
    final mergedIds = <int>{};

    if (effectiveLang != 'all') {
      final tagIds = await HitomiNozomi.fetchTagGalleryIdsByOffset(
        primaryTerm,
        offset,
        count,
        language: effectiveLang,
      );
      mergedIds.addAll(tagIds);
    }

    if (mergedIds.length < count) {
      final parallelFutures = <Future<List<int>>>[
        if (mergedIds.isEmpty && (explicitLang == null || explicitLang.isEmpty))
          HitomiNozomi.fetchTagGalleryIdsByOffset(
            primaryTerm,
            offset,
            count,
            language: 'all',
          ),
        HitomiNozomi.fetchGalleryIdsByOffset(
          HitomiNozomi.getArtistIndexUrl(
            primaryTerm,
            effectiveLang != 'all' ? effectiveLang : 'all',
          ),
          offset,
          count,
        ),
        HitomiNozomi.fetchGalleryIdsByOffset(
          HitomiNozomi.getSeriesIndexUrl(
            primaryTerm,
            effectiveLang != 'all' ? effectiveLang : 'all',
          ),
          offset,
          count,
        ),
        HitomiNozomi.searchTitleWordGalleryIds(
          primaryTerm,
          language: effectiveLang,
        ),
      ];
      final parallelResults = await Future.wait(parallelFutures);
      for (final list in parallelResults) {
        mergedIds.addAll(list);
      }
    }

    if (mergedIds.isEmpty) return const <int>[];
    final sorted = mergedIds.toList()..sort((a, b) => b.compareTo(a));
    if (offset >= sorted.length) return const <int>[];
    final end =
        (offset + count < sorted.length) ? offset + count : sorted.length;
    return sorted.sublist(offset, end);
  }

  /// E-Hentai 검색 쿼리 정규화 (언더스코어를 공백으로 변환 및 lang -> language 변환)
  static String formatEHentaiQuery(String cleanQuery, String targetLang) {
    final filteredTokens = cleanQuery
        .split(RegExp(r'\s+'))
        .where((raw) {
          final t = raw.trim().toLowerCase();
          if (t.isEmpty) return false;
          final core = t.startsWith('-') ? t.substring(1) : t;
          if (core.startsWith('id:') ||
              RegExp(r'^id(?:!=|>=|<=|==|>|<|=)\d+$').hasMatch(core)) {
            return false;
          }
          if (t.startsWith('-') && int.tryParse(core) != null) return false;
          if (RegExp(r'^(?:page|date|published)(?:>=|<=|==|>|<|=|:)').hasMatch(core)) {
            return false;
          }
          return true;
        })
        .join(' ');
    var q = filteredTokens
        .replaceAll(RegExp(r'\blang:', caseSensitive: false), 'language:')
        .replaceAll('_', ' ')
        .trim();
    if (q.toLowerCase().contains('language:')) {
      // 이미 쿼리에 language 태그가 명시되어 있다면 추가 prefix 없이 그대로 사용
      return q;
    }
    if (targetLang == 'all') return q;
    final langPrefix = 'language:$targetLang';
    return q.isEmpty ? langPrefix : '$langPrefix $q';
  }

  /// Hitomi에서 수집된 작품 목록에 대해 로컬 DB, 북마크 DB, E-Hentai 대조군을 종합 검증하여
  /// 기존 Violet/E-Hentai에 존재하는 작품은 'common'으로 확정 승격하고,
  /// 오직 어디에도 존재하지 않는 순수 Hitomi 독점작만 'hitomi_only'로 확정합니다.
  static Future<void> verifyAndTagHitomiArticles(
    List<QueryResult> items, {
    Set<int>? knownEhIds,
    Set<String>? knownEhTitles,
    bool allowMarkHitomiOnly = true,
  }) async {
    if (items.isEmpty) return;

    final idListStr = items.map((e) => e.id()).join(',');

    // 1) 로컬 DB(HitomiColumnModel) ID 및 제목 매칭
    try {
      final db = await DataBaseManager.getInstance();
      if (db.db != null && db.db!.isOpen && idListStr.isNotEmpty) {
        // ID 매칭
        final dbMatches = await db.query(
          'SELECT Id, Title, EHash FROM HitomiColumnModel WHERE Id IN ($idListStr)',
        );
        for (final row in dbMatches) {
          final rid = row['Id'] as int?;
          if (rid != null) {
            for (final item in items) {
              if (item.id() == rid) {
                item.result['source'] = 'common';
                item.result['is_common'] = true;
                if (row['EHash'] != null) item.result['EHash'] = row['EHash'];
                _sessionBadgeCache[rid] = 'common';
              }
            }
          }
        }

        // 제목 기반 매칭 (아직 common이 아닌 항목)
        for (final item in items) {
          if (item.result['is_common'] == true) continue;
          final tokens = extractTitleTokens(item.title() ?? '');
          for (final tok in tokens) {
            if (tok.length < 4) continue;
            final safeTok = tok.replaceAll("'", "''");
            try {
              final matches = await db.query(
                "SELECT Id, Title, EHash FROM HitomiColumnModel WHERE Title LIKE '%$safeTok%' LIMIT 3",
              );
              for (final mRow in matches) {
                final dbTitle = mRow['Title'] as String? ?? '';
                if (isTitleMatched(item.title() ?? '', dbTitle)) {
                  item.result['source'] = 'common';
                  item.result['is_common'] = true;
                  if (mRow['EHash'] != null) item.result['EHash'] = mRow['EHash'];
                  _sessionBadgeCache[item.id()] = 'common';
                  break;
                }
              }
            } catch (_) {}
            if (item.result['is_common'] == true) break;
          }
        }
      }
    } catch (_) {}

    // 2) 북마크 DB(user.db) 대조: 사용자의 북마크에 있는 작품은 공통(common)으로 확정
    try {
      final bookmark = await Bookmark.getInstance();
      for (final item in items) {
        if (item.result['is_common'] == true) continue;
        if (await bookmark.isBookmark(item.id())) {
          item.result['source'] = 'common';
          item.result['is_common'] = true;
          _sessionBadgeCache[item.id()] = 'common';
        }
      }
    } catch (_) {}

    // 3) 외부에서 전달된 E-Hentai 대조군(knownEhIds, knownEhTitles) 확인
    if (knownEhIds != null || knownEhTitles != null) {
      for (final item in items) {
        if (item.result['is_common'] == true) continue;
        if (knownEhIds != null && knownEhIds.contains(item.id())) {
          item.result['source'] = 'common';
          item.result['is_common'] = true;
          _sessionBadgeCache[item.id()] = 'common';
          continue;
        }
        if (knownEhTitles != null && knownEhTitles.isNotEmpty) {
          final iTitle = item.title() ?? '';
          for (final ehTitle in knownEhTitles) {
            if (isTitleMatched(iTitle, ehTitle)) {
              item.result['source'] = 'common';
              item.result['is_common'] = true;
              _sessionBadgeCache[item.id()] = 'common';
              break;
            }
          }
        }
      }
    }

    // 4) 철저한 검증 후 판정 확정: E-Hentai 대조가 정상 응답한 경우에만 순수 Hitomi 독점작을 hitomi_only로 확정
    for (final item in items) {
      if (item.result['source'] == 'ehentai' || item.result['source'] == 'violet') continue;
      if (item.result['is_common'] == true ||
          item.result['source'] == 'common' ||
          item.ehash() != null) {
        item.result['source'] = 'common';
        item.result['is_common'] = true;
        _sessionBadgeCache[item.id()] = 'common';
      } else if (allowMarkHitomiOnly) {
        item.result['source'] = 'hitomi_only';
        item.result['is_hitomi_only'] = true;
        _sessionBadgeCache[item.id()] = 'hitomi_only';
      } else {
        item.result['source'] = 'hitomi';
      }
    }
  }

  /// E-Hentai와 Hitomi 둘 다에서 보이는 공통 작품은 철저히 제외하고,
  /// 오직 Hitomi에서만 불러올 수 있는 순수 독점/단독 최신 작품만 필터링하여 반환합니다.
  /// 공통 작품으로 인해 이번 페이지 결과가 비어있더라도, Hitomi 인덱스가 남아있는 한
  /// 연속 탐색하여 최소한의 독점 작품을 확보한 뒤 반환합니다.
  static Future<({List<QueryResult> results, int nextScanPage, bool hasMore})> fetchHitomiOnlyArticles({
    String query = '',
    int page = 1,
    int pageSize = 30,
  }) async {
    final cleanQuery = query.trim();
    final selectedLangs = getSelectedLanguages();
    String targetLang = selectedLangs.length == 1 ? selectedLangs.first : 'all';

    final accumulatedHitomiOnly = <QueryResult>[];
    var currentPage = page;
    var consecutiveEmptyBatches = 0;
    bool hasMore = true;

    // E-Hentai 최신 피드는 1회만 조회하여 루프 간 공유
    final ehIds = <int>{};
    final ehTitles = <String>{};
    bool ehFetched = false;

    while (accumulatedHitomiOnly.length < 15 && consecutiveEmptyBatches < 6) {
      final ids = await fetchGalleryIdsForQuery(
        query: cleanQuery,
        page: currentPage,
        pageSize: pageSize,
        targetLang: targetLang,
      );

      // Hitomi Nozomi 범위 바이트가 완전히 끝난 경우 (진짜 인덱스 종료)
      if (ids.isEmpty) {
        hasMore = false;
        break;
      }

      // Hitomi 메타데이터 병렬 로딩
      final hitomiList = <QueryResult>[];
      const chunkSize = 25;
      for (var i = 0; i < ids.length; i += chunkSize) {
        final end = (i + chunkSize < ids.length) ? i + chunkSize : ids.length;
        final chunk = ids.sublist(i, end);
        final chunkFutures = chunk.map((id) => _idQueryHitomiFast(id));
        hitomiList.addAll(await Future.wait(chunkFutures));
      }

      if (hitomiList.isEmpty) {
        currentPage++;
        consecutiveEmptyBatches++;
        continue;
      }

      // 1) 세션 캐시 확인: 이미 분류된 작품은 네트워크/DB 대조 없이 즉시 처리
      final uncachedHitomiList = <QueryResult>[];
      final candidates = <QueryResult>[];

      for (final hQr in hitomiList) {
        final cached = _sessionBadgeCache[hQr.id()];
        if (cached != null) {
          if (cached == 'hitomi_only') {
            hQr.result['is_hitomi_only'] = true;
            hQr.result['source'] = 'hitomi_only';
            candidates.add(hQr);
          }
          continue;
        }
        uncachedHitomiList.add(hQr);
      }

      // 2) 캐시되지 않은 신규 ID만 DB 및 E-Hentai 대조군 마련
      if (uncachedHitomiList.isNotEmpty) {
        if (!ehFetched) {
          ehFetched = true;
          try {
            final ehQuery = formatEHentaiQuery(cleanQuery, targetLang);
            final ehList = await HentaiManager.searchEHentai(ehQuery, 0)
                .timeout(const Duration(seconds: 3), onTimeout: () => <QueryResult>[]);
            for (final item in ehList) {
              ehIds.add(item.id());
              if ((item.title() ?? '').isNotEmpty) {
                ehTitles.add(item.title()!);
              }
            }
          } catch (_) {}
        }

        await verifyAndTagHitomiArticles(
          uncachedHitomiList,
          knownEhIds: ehIds,
          knownEhTitles: ehTitles,
        );

        for (final hQr in uncachedHitomiList) {
          if (hQr.result['is_hitomi_only'] == true) {
            candidates.add(hQr);
          }
        }
      }

      if (candidates.isNotEmpty) {
        accumulatedHitomiOnly.addAll(candidates);
      } else {
        consecutiveEmptyBatches++;
      }
      currentPage++;
    }

    accumulatedHitomiOnly.sort((a, b) => b.id().compareTo(a.id()));
    return (
      results: accumulatedHitomiOnly,
      nextScanPage: currentPage,
      hasMore: hasMore,
    );
  }

  static bool _articleCacheTableInitialized = false;

  static Future<void> _ensureArticleCacheTable(DataBaseManager db) async {
    if (_articleCacheTableInitialized) return;
    try {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS ArticleCache (Id INTEGER PRIMARY KEY, Data TEXT)',
      );
      _articleCacheTableInitialized = true;
    } catch (_) {}
  }

  static QueryResult? getCachedMetadata(int id) {
    final cached = _sessionMetadataCache[id];
    if (cached != null) {
      return QueryResult(result: Map<String, dynamic>.from(cached.result));
    }
    return null;
  }

  static final Map<int, String> _pendingDiskWrites = <int, String>{};
  static Timer? _diskWriteDebounceTimer;

  static void cacheMetadata(QueryResult qr) {
    final id = qr.id();
    _sessionMetadataCache[id] = qr;

    // 디스크(user.db) 영구 캐시 250ms 디바운스 Batch 저장 (Write Storm 방지)
    try {
      _pendingDiskWrites[id] = jsonEncode(qr.result);
    } catch (_) {}

    _diskWriteDebounceTimer?.cancel();
    _diskWriteDebounceTimer = Timer(
      const Duration(milliseconds: 250),
      _flushPendingDiskWrites,
    );
  }

  static Future<void> _flushPendingDiskWrites() async {
    if (_pendingDiskWrites.isEmpty) return;
    final entries = Map<int, String>.from(_pendingDiskWrites);
    _pendingDiskWrites.clear();

    try {
      final db = await CommonUserDatabase.getInstance();
      await _ensureArticleCacheTable(db);
      final rawDb = db.db;
      if (rawDb != null && rawDb.isOpen) {
        final batch = rawDb.batch();
        for (final entry in entries.entries) {
          batch.insert(
            'ArticleCache',
            {'Id': entry.key, 'Data': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
    } catch (e) {
      Logger.warning('[HybridLoader.cacheMetadata] batch disk cache error: $e');
    }
  }

  /// ids 목록 중 이미 ArticleCache(로컬 디스크)에 저장된 메타데이터를 일괄 조회
  static Future<Map<int, QueryResult>> getCachedMetadataBatch(
    List<int> ids,
  ) async {
    final result = <int, QueryResult>{};
    if (ids.isEmpty) return result;

    // 1. 메모리 캐시 먼저 확인
    final missingIds = <int>[];
    for (final id in ids) {
      final mem = _sessionMetadataCache[id];
      if (mem != null) {
        result[id] = QueryResult(result: Map<String, dynamic>.from(mem.result));
      } else {
        missingIds.add(id);
      }
    }

    if (missingIds.isEmpty) return result;

    // 2. 디스크 캐시(user.db)에서 일괄 쿼리
    try {
      final db = await CommonUserDatabase.getInstance();
      await _ensureArticleCacheTable(db);

      const int chunkSize = 500;
      for (var i = 0; i < missingIds.length; i += chunkSize) {
        final chunk = missingIds.sublist(
          i,
          i + chunkSize > missingIds.length ? missingIds.length : i + chunkSize,
        );
        final rows = await db.query(
          'SELECT Id, Data FROM ArticleCache WHERE Id IN (${chunk.join(',')})',
        );
        for (final row in rows) {
          try {
            final id = row['Id'] as int;
            final dataStr = row['Data'] as String;
            final map = jsonDecode(dataStr) as Map<String, dynamic>;
            if (map['source'] == 'pupil') map['source'] = 'hitomi';
            if (map['source'] == 'violet') map['source'] = 'ehentai';
            if (map['source'] == 'pupil_only') map['source'] = 'hitomi_only';
            if (map['is_pupil_only'] == true) {
              map.remove('is_pupil_only');
              map['is_hitomi_only'] = true;
            }
            final qr = QueryResult(result: map);
            _sessionMetadataCache[id] = qr;
            result[id] = qr;
          } catch (_) {}
        }
      }
    } catch (e) {
      Logger.warning('[HybridLoader.getCachedMetadataBatch] error: $e');
    }

    return result;
  }

  /// 외부 호출용 초고속 Hitomi 경량 로더 (galleryblock HTML 1회 호출)
  static Future<QueryResult> idQueryHitomiFast(int id) async =>
      _idQueryHitomiFast(id);

  /// galleryinfo.js 2차 요청 없이 galleryblock HTML 1회 요청만으로
  /// 검색 목록에 필요한 핵심 메타데이터를 초고속 수집하는 경량 로더
  static Future<QueryResult> _idQueryHitomiFast(int id) async {
    final cached = _sessionMetadataCache[id];
    if (cached != null) {
      return QueryResult(result: Map<String, dynamic>.from(cached.result));
    }

    try {
      final headers =
          await ScriptManager.runHitomiGetHeaderContent(id.toString());
      final res = await http.get(
        'https://ltn.gold-usergeneratedcontent.net/galleryblock/$id.html',
        headers: headers,
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode != 200) throw Exception('status ${res.statusCode}');
      final article = await HitomiParser.parseGalleryBlock(res.body);

      String encodePipeValues(List<String>? list) {
        if (list == null || list.isEmpty) return 'N/A';
        return '|${list.join('|')}|';
      }

      final meta = {
        'Id': id,
        'Title': article['Title'] ?? '#$id',
        'Artists': encodePipeValues(
          article['Artists'] is List<String>
              ? article['Artists'] as List<String>
              : null,
        ),
        'Groups': null,
        'Characters': null,
        'Series': encodePipeValues(
          article['Series'] is List<String>
              ? article['Series'] as List<String>
              : null,
        ),
        'Tags': encodePipeValues(
          article['Tags'] is List<String>
              ? article['Tags'] as List<String>
              : null,
        ),
        'Files': null,
        'Type': article['Type'] ?? 'N/A',
        'Language': article['Language'] ?? 'N/A',
        'Published': article['Published'],
        'Thumbnail': article['Thumbnail'],
        'ExistOnHitomi': 1,
        'source': 'hitomi',
      };
      final qr = QueryResult(result: meta);
      _sessionMetadataCache[id] = qr;
      cacheMetadata(qr);
      return qr;
    } catch (e) {
      final expungedQr = await ExpungedDatabaseManager.queryId(id);
      if (expungedQr != null) {
        _sessionMetadataCache[id] = expungedQr;
        cacheMetadata(expungedQr);
        return expungedQr;
      }
      return QueryResult(
        result: {'Id': id, 'Title': '#$id', 'ExistOnHitomi': 1, 'source': 'hitomi'},
      );
    }
  }

  /// 메인 화면용 하이브리드 작품 로더 (기본 검색 시 호출)
  /// E-Hentai와 Hitomi(Nozomi)에서 불러온 모든 작품을
  /// 병렬로 수집하여 중복 제거 후 합쳐서 반환합니다.
  /// 둘 다 존재하는 작품은 'common', Hitomi만 있는 작품은 'hitomi', E-Hentai만 있는 작품은 'violet' 소스 뱃지가 부여됩니다.
  static Future<List<QueryResult>> fetchMainHybridArticles({
    String query = '',
    int page = 1,
    int pageSize = 50,
    SearchSortMode sortMode = SearchSortMode.latest,
  }) async {
    final cleanQuery = query.trim();

    // 순수 숫자(품번) 또는 id:숫자 단독 검색인 경우 직결 처리 (초고속 1건 반환, 부정형 -12345 제외)
    final numericId = !cleanQuery.startsWith('-')
        ? (int.tryParse(cleanQuery) ??
            (cleanQuery.toLowerCase().startsWith('id:')
                ? int.tryParse(cleanQuery.substring(3).trim())
                : null))
        : null;
    if (numericId != null && numericId > 0) {
      if (page > 1) return [];
      try {
        final hitomiQr = await _idQueryHitomiFast(numericId);
        try {
          final db = await DataBaseManager.getInstance();
          if (db.db != null && db.db!.isOpen) {
            final dbMatches = await db.query(
              'SELECT * FROM HitomiColumnModel WHERE Id = $numericId',
            );
            if (dbMatches.isNotEmpty) {
              final row = dbMatches.first;
              hitomiQr.result.addAll(row);
              hitomiQr.result['source'] = 'common';
              hitomiQr.result['is_common'] = true;
            }
          }
        } catch (_) {}
        if (hitomiQr.result['is_common'] != true &&
            hitomiQr.result['source'] != 'common') {
          try {
            final ehash = await tryGetEhHash(numericId, false)
                .timeout(const Duration(seconds: 2));
            hitomiQr.result['EHash'] = ehash;
            hitomiQr.result['source'] = 'common';
            hitomiQr.result['is_common'] = true;
            _sessionBadgeCache[numericId] = 'common';
          } catch (e) {
            if (e.toString().contains('Cannot find hash')) {
              hitomiQr.result['source'] = 'hitomi_only';
              hitomiQr.result['is_hitomi_only'] = true;
              _sessionBadgeCache[numericId] = 'hitomi_only';
            }
          }
        }
        return [hitomiQr];
      } catch (e, st) {
        Logger.error('[HybridLoader-NumericIdQuery] E: $e\n$st');
        return [];
      }
    }

    final selectedLangs = getSelectedLanguages();
    String targetLang = selectedLangs.length == 1 ? selectedLangs.first : 'all';

    // 1) 정렬 조건(order:) 추출
    SearchSortMode effectiveSortMode = sortMode;
    final orderMatch = RegExp(r'(?:^|[\s\(])order:([a-zA-Z0-9_-]+)', caseSensitive: false).firstMatch(cleanQuery);
    if (orderMatch != null) {
      final o = orderMatch.group(1)!.toLowerCase();
      if (o == 'week' || o == 'popular-week') {
        effectiveSortMode = SearchSortMode.popularWeek;
      } else if (o == 'month' || o == 'popular-month') {
        effectiveSortMode = SearchSortMode.popularMonth;
      } else if (o == 'year' || o == 'popular-year') {
        effectiveSortMode = SearchSortMode.popularYear;
      } else if (o == 'today' || o == 'popular-today') {
        effectiveSortMode = SearchSortMode.popularToday;
      } else if (o == 'popular' || o == 'all' || o == 'popular-all') {
        effectiveSortMode = SearchSortMode.popularAll;
      } else if (o == 'latest') {
        effectiveSortMode = SearchSortMode.latest;
      }
    }

    // 2) 언어 토큰 분석 및 정규화
    bool hasExplicitLang = false;
    bool isLanguageToken(String rawToken) {
      final t = rawToken.replaceAll(RegExp(r'[\(\)]'), '').trim().toLowerCase();
      if (t.isEmpty) return true;
      if (t.startsWith('lang:') || t.startsWith('language:')) {
        hasExplicitLang = true;
        final langVal = t.split(':').last.trim();
        if (langVal == 'ko' || langVal == 'korea' || langVal == 'korean' || langVal == '한국어') {
          targetLang = 'korean';
        } else if (langVal == 'ja' || langVal == 'japan' || langVal == 'japanese' || langVal == '일본어') {
          targetLang = 'japanese';
        } else if (langVal == 'en' || langVal == 'english' || langVal == '영어') {
          targetLang = 'english';
        } else if (langVal == 'zh' || langVal == 'chinese' || langVal == '중국어') {
          targetLang = 'chinese';
        } else {
          targetLang = langVal;
        }
        return true;
      }
      if (t == 'korean' || t == 'ko' || t == 'korea' || t == '한국어') {
        hasExplicitLang = true;
        targetLang = 'korean';
        return true;
      }
      if (t == 'japanese' || t == 'ja' || t == 'japan' || t == '일본어') {
        hasExplicitLang = true;
        targetLang = 'japanese';
        return true;
      }
      if (t == 'english' || t == 'en' || t == '영어') {
        hasExplicitLang = true;
        targetLang = 'english';
        return true;
      }
      if (t == 'chinese' || t == 'zh' || t == '중국어') {
        hasExplicitLang = true;
        targetLang = 'chinese';
        return true;
      }
      if (t == 'tag:korean' || t == 'tag:japanese' || t == 'tag:english' || t == 'tag:chinese') {
        hasExplicitLang = true;
        return true;
      }
      return false;
    }

    // 3) random 검색 및 seed 분리
    bool isRandom = false;
    double? randomSeed;
    final queryTokens = cleanQuery.split(' ');
    if (queryTokens.any((x) => x == 'random' || x.startsWith('random:'))) {
      isRandom = true;
      for (final t in queryTokens) {
        if (t.startsWith('random:')) {
          randomSeed = double.tryParse(t.split('random:').last);
          break;
        }
      }
      randomSeed ??= (DateTime.now().microsecondsSinceEpoch % 10000) / 1000.0 + 1.0;
    }

    // 온라인 및 태그 검색용 순수 검색어 (random, order 제외)
    final pureTokens = queryTokens.where(
      (x) => x != 'random' && !x.startsWith('random:') && !x.startsWith('order:'),
    ).toList();

    // 언어 토큰까지 검사하여 targetLang을 추출하고 비언어 토큰만 분리
    final nonLangTokens = pureTokens.where((x) => !isLanguageToken(x)).toList();
    final pureQueryWithoutLang = nonLangTokens
        .map((x) => x.replaceAll(RegExp(r'[\(\)]'), '').trim())
        .where((x) => x.isNotEmpty)
        .join(' ')
        .trim();

    final pureQuery = pureTokens.join(' ').trim();

    // 사용자가 쿼리에 언어를 명시하지 않은 상태에서 인기순을 선택한 경우 전체(all) 인기순으로 라우팅
    if (effectiveSortMode != SearchSortMode.latest && !hasExplicitLang) {
      targetLang = 'all';
    }

    // 2) 번호(Id) 및 날짜(Date) 범위 필터 추출 (부정형 -id: 등은 제외하고 긍정 조건만 추출)
    int? filterMinId;
    int? filterMaxId;
    for (final rawTok in nonLangTokens) {
      final tok = rawTok.replaceAll(RegExp(r'[\(\)]'), '').trim().toLowerCase();
      if (tok.isEmpty || tok.startsWith('-')) continue;
      final idRangeMatch =
          RegExp(r'^id:(\d+)(?:~|\.\.|\-)(\d+)$').firstMatch(tok);
      if (idRangeMatch != null) {
        filterMinId = int.tryParse(idRangeMatch.group(1)!);
        filterMaxId = int.tryParse(idRangeMatch.group(2)!);
      }
      final idGteMatch = RegExp(r'^id(?:>=|>)(\d+)$').firstMatch(tok);
      if (idGteMatch != null) {
        final v = int.tryParse(idGteMatch.group(1)!);
        if (v != null) filterMinId = tok.contains('>=') ? v : v + 1;
      }
      final idLteMatch = RegExp(r'^id(?:<=|<)(\d+)$').firstMatch(tok);
      if (idLteMatch != null) {
        final v = int.tryParse(idLteMatch.group(1)!);
        if (v != null) filterMaxId = tok.contains('<=') ? v : v - 1;
      }
      final idEqMatch = RegExp(r'^id(?:==|=)(\d+)$').firstMatch(tok);
      if (idEqMatch != null) {
        final v = int.tryParse(idEqMatch.group(1)!);
        if (v != null) {
          filterMinId = v;
          filterMaxId = v;
        }
      }
    }

    DateTime? filterMinDate;
    DateTime? filterMaxDate;
    final dateRangeMatch = RegExp(r'(?:date|published):(\d{4}(?:-\d{2}-\d{2})?)(?:~|\.\.)(\d{4}(?:-\d{2}-\d{2})?)', caseSensitive: false).firstMatch(cleanQuery);
    if (dateRangeMatch != null) {
      var sStr = dateRangeMatch.group(1)!;
      var eStr = dateRangeMatch.group(2)!;
      if (sStr.length == 4) sStr = '$sStr-01-01';
      if (eStr.length == 4) eStr = '$eStr-12-31';
      filterMinDate = DateTime.tryParse(sStr);
      filterMaxDate = DateTime.tryParse('$eStr 23:59:59');
    }
    final dateGteMatch = RegExp(r'(?:date|published)(?:>=|>)(\d{4}(?:-\d{2}-\d{2})?)', caseSensitive: false).firstMatch(cleanQuery);
    if (dateGteMatch != null) {
      var sStr = dateGteMatch.group(1)!;
      if (sStr.length == 4) sStr = '$sStr-01-01';
      filterMinDate = DateTime.tryParse(sStr);
    }
    final dateLteMatch = RegExp(r'(?:date|published)(?:<=|<)(\d{4}(?:-\d{2}-\d{2})?)', caseSensitive: false).firstMatch(cleanQuery);
    if (dateLteMatch != null) {
      var eStr = dateLteMatch.group(1)!;
      if (eStr.length == 4) eStr = '$eStr-12-31';
      filterMaxDate = DateTime.tryParse('$eStr 23:59:59');
    }

    // 1) Hitomi: fetchGalleryIdsForQuery 사용 (random 태그 제외한 pureQuery 사용)
    final hitomiFuture = Future<List<QueryResult>>(() async {
      try {
        List<int> ids = [];
        if (effectiveSortMode != SearchSortMode.latest && pureQueryWithoutLang.isEmpty) {
          final popularUrl = HitomiNozomi.getPopularIndexUrl(effectiveSortMode, targetLang);
          ids = await HitomiNozomi.fetchGalleryIds(popularUrl, page, pageSize: pageSize);
        } else if (isRandom) {
          ids = await fetchRandomGalleryIdsForQuery(
            query: pureQuery,
            targetLang: targetLang,
            selectedLangs: selectedLangs,
            count: pageSize,
            seed: randomSeed,
            page: page,
          );
        } else if (pureQuery.isEmpty && selectedLangs.length > 1) {
          // 복수 언어가 설정된 경우 각 언어 인덱스를 분할/병렬 로드하여 합침
          final subPageSize = (pageSize / selectedLangs.length).ceil() + 5;
          final subIds = await Future.wait(
            selectedLangs.map((lang) => HitomiNozomi.fetchGalleryIds(
              HitomiNozomi.getLanguageIndexUrl(lang),
              page,
              pageSize: subPageSize,
            )),
          );
          final mergedSet = <int>{};
          for (final list in subIds) {
            mergedSet.addAll(list);
          }
          ids = mergedSet.toList();
        } else {
          ids = await fetchGalleryIdsForQuery(
            query: pureQuery,
            page: page,
            pageSize: pageSize,
            targetLang: targetLang,
          );
        }
        if (ids.isEmpty) return [];

        // 불필요한 네트워크 호출 방지를 위해 쿼리/설정에서 제외된 품번 ID 사전 제거
        final queryTokensForIdFilter =
            pureQuery.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toSet();
        ids = ids.where((id) {
          if (_isIdExcludedByQueryTokens(id, nonLangTokens)) return false;
          if (Settings.excludeTags.value.isNotEmpty) {
            final idStr = id.toString();
            for (final rawRule in Settings.excludeTags.value) {
              if (!Settings.isIdExcludeRule(rawRule)) continue;
              if (queryTokensForIdFilter.contains(idStr) ||
                  queryTokensForIdFilter.contains('id:$idStr')) {
                continue;
              }
              if (Settings.matchesIdRule(id, rawRule)) return false;
            }
          }
          return true;
        }).toList();
        if (ids.isEmpty) return [];

        final hitomiList = <QueryResult>[];
        const chunkSize = 25;
        for (var i = 0; i < ids.length; i += chunkSize) {
          final end = (i + chunkSize < ids.length) ? i + chunkSize : ids.length;
          final chunk = ids.sublist(i, end);
          final chunkFutures = chunk.map((id) => _idQueryHitomiFast(id));
          hitomiList.addAll(await Future.wait(chunkFutures));
        }
        for (final qr in hitomiList) {
          if (qr.result['is_common'] != true &&
              qr.result['source'] != 'common' &&
              qr.result['source'] != 'ehentai' &&
              qr.result['source'] != 'violet') {
            qr.result['source'] ??= 'hitomi';
          }
        }
        return hitomiList;
      } catch (e, st) {
        Logger.error('[HybridLoader-Main-Hitomi] E: $e\n$st');
        return [];
      }
    }).timeout(
      const Duration(seconds: 12),
      onTimeout: () => <QueryResult>[],
    );

    // 2) E-Hentai 검색 (random 태그 제외한 pureQuery 사용)
    var ehSucceeded = false;
    final violetFuture = Future<List<QueryResult>>(() async {
      if (effectiveSortMode != SearchSortMode.latest && pureQueryWithoutLang.isEmpty) return [];
      try {
        final ehQuery = formatEHentaiQuery(pureQuery, targetLang);
        if (pageSize <= 25) {
          final offset = (page - 1) * pageSize;
          final list = await HentaiManager.searchEHentai(ehQuery, offset);
          ehSucceeded = true;
          for (final qr in list) {
            qr.result['source'] = 'ehentai';
          }
          return list;
        } else {
          final pagesToFetch = (pageSize / 25).ceil();
          final baseOffset = (page - 1) * pageSize;
          final futures = List.generate(
            pagesToFetch,
            (i) => HentaiManager.searchEHentai(ehQuery, baseOffset + i * 25),
          );
          final pagesResults = await Future.wait(futures);
          ehSucceeded = true;
          final mergedList = <QueryResult>[];
          for (final list in pagesResults) {
            for (final qr in list) {
              qr.result['source'] = 'ehentai';
            }
            mergedList.addAll(list);
          }
          return mergedList;
        }
      } catch (e, st) {
        Logger.error('[HybridLoader-Main-Violet] E: $e\n$st');
        return [];
      }
    }).timeout(
      const Duration(seconds: 10),
      onTimeout: () => <QueryResult>[],
    );

    // 3) 로컬 DB + Expunged DB: HitomiColumnModel 검색 (Triple Hybrid, random 지원)
    final localDbFuture = Future<List<QueryResult>>(() async {
      if (effectiveSortMode != SearchSortMode.latest && pureQueryWithoutLang.isEmpty) return [];
      try {
        final db = await DataBaseManager.getInstance();
        final hasMainDb = db.db != null && db.db!.isOpen;
        final expungedDb = await ExpungedDatabaseManager.getInstance();
        final hasExpungedDb = expungedDb != null && expungedDb.isOpen;

        if (!hasMainDb && !hasExpungedDb) return [];

        String sqlQuery;
        final offset = (page - 1) * pageSize;
        final orderBy = isRandom
            ? 'ORDER BY Id * $randomSeed - ROUND(Id * $randomSeed - 0.5, 0) DESC'
            : 'ORDER BY Id DESC';

        if (pureQuery.isEmpty) {
          if (targetLang != 'all') {
            sqlQuery = 'SELECT * FROM HitomiColumnModel WHERE Language=\'$targetLang\' $orderBy LIMIT $pageSize OFFSET $offset';
          } else {
            sqlQuery = 'SELECT * FROM HitomiColumnModel $orderBy LIMIT $pageSize OFFSET $offset';
          }
        } else {
          final translated = translate2query(pureQuery, filter: false);
          sqlQuery = '$translated $orderBy LIMIT $pageSize OFFSET $offset';
        }

        final combinedResults = <QueryResult>[];
        if (hasMainDb) {
          try {
            final rows = await db.query(sqlQuery);
            for (final r in rows) {
              final map = Map<String, dynamic>.from(r);
              map['source'] = 'common';
              map['is_common'] = true;
              combinedResults.add(QueryResult(result: map));
            }
          } catch (_) {}
        }

        if (hasExpungedDb) {
          try {
            final expRows = await expungedDb.rawQuery(sqlQuery);
            for (final r in expRows) {
              final map = Map<String, dynamic>.from(r);
              map['source'] = 'common';
              map['is_common'] = true;
              map['is_expunged'] = true;
              combinedResults.add(QueryResult(result: map));
            }
          } catch (_) {}
        }

        return combinedResults;
      } catch (_) {
        return [];
      }
    }).timeout(
      const Duration(seconds: 3),
      onTimeout: () => <QueryResult>[],
    );

    final responses = await Future.wait([hitomiFuture, violetFuture, localDbFuture])
        .timeout(
          const Duration(seconds: 14),
          onTimeout: () => [<QueryResult>[], <QueryResult>[], <QueryResult>[]],
        );
    final hitomiList = responses[0];
    final violetList = responses[1];
    final localDbList = responses[2];

    final merged = <QueryResult>[];
    final seenIds = <int>{};
    final seenTitles = <String>{};

    // 로컬 DB 검색 결과 우선 반영 (Violet 공식 DB에 존재하는 100% 공통 작품)
    for (final lItem in localDbList) {
      final lId = lItem.id();
      final lTitle = lItem.title() ?? '';
      seenIds.add(lId);
      if (lTitle.isNotEmpty) seenTitles.add(normalizeTitle(lTitle));
      _sessionBadgeCache[lId] = 'common';
      merged.add(lItem);
    }

    // Hitomi 최신 결과 반영
    for (final item in hitomiList) {
      final id = item.id();
      final title = item.title() ?? '';

      // 이미 로컬 DB에 등록된 작품인 경우 승격
      if (seenIds.contains(id)) {
        final existing = merged.where((m) => m.id() == id).firstOrNull;
        if (existing != null) {
          existing.result['source'] = 'common';
          existing.result['is_common'] = true;
          _sessionBadgeCache[id] = 'common';
        }
        continue;
      }

      final existingByTitle = merged.where((m) =>
          isLanguageMatched(m, item) &&
          isTitleMatched(m.title() ?? '', title)).firstOrNull;
      if (existingByTitle != null) {
        existingByTitle.result['source'] = 'common';
        existingByTitle.result['is_common'] = true;
        _sessionBadgeCache[existingByTitle.id()] = 'common';
        continue;
      }

      seenIds.add(id);
      if (title.isNotEmpty) seenTitles.add(normalizeTitle(title));
      merged.add(item);
    }

    // E-Hentai 결과 추가 병합 및 공통 작품 승격
    final ehIds = <int>{};
    final ehTitles = <String>{};
    for (final vItem in violetList) {
      final vId = vItem.id();
      final vTitle = vItem.title() ?? '';
      ehIds.add(vId);
      if (vTitle.isNotEmpty) ehTitles.add(vTitle);

      final existing = merged.where((m) {
        if (m.id() == vId) return true;
        return isLanguageMatched(m, vItem) && isTitleMatched(m.title() ?? '', vTitle);
      }).firstOrNull;

      if (existing != null) {
        existing.result['source'] = 'common';
        existing.result['is_common'] = true;
        if (vItem.ehash() != null) existing.result['EHash'] = vItem.ehash();
        _sessionBadgeCache[existing.id()] = 'common';
      } else {
        if (!seenIds.contains(vId)) {
          seenIds.add(vId);
          vItem.result['source'] = 'ehentai';
          _sessionBadgeCache[vId] = 'ehentai';
          merged.add(vItem);
        }
      }
    }

    // 로컬 DB, 북마크 DB, E-Hentai 대조군을 통해 Hitomi 작품 전수 정밀 검증
    final hitomiItems = merged.where((m) => m.result['source'] == 'hitomi').toList();
    if (hitomiItems.isNotEmpty) {
      await verifyAndTagHitomiArticles(
        hitomiItems,
        knownEhIds: ehIds,
        knownEhTitles: ehTitles,
        allowMarkHitomiOnly: ehSucceeded,
      );
    }

    // 번호(Id) 및 날짜(Date) 범위 필터 적용
    if (filterMinId != null || filterMaxId != null || filterMinDate != null || filterMaxDate != null) {
      merged.retainWhere((item) {
        final id = item.id();
        if (filterMinId != null && id < filterMinId) return false;
        if (filterMaxId != null && id > filterMaxId) return false;
        if (filterMinDate != null || filterMaxDate != null) {
          final dt = item.getDateTime();
          if (dt != null) {
            if (filterMinDate != null && dt.isBefore(filterMinDate)) return false;
            if (filterMaxDate != null && dt.isAfter(filterMaxDate)) return false;
          }
        }
        return true;
      });
    }

    // 제외 태그(Settings.excludeTags) 필터링 적용 (단일 진실 공급원 SSOT)
    if (Settings.excludeTags.value.isNotEmpty) {
      merged.removeWhere((item) => Settings.isExcluded(item, currentQuery: pureQuery));
    }

    // 복합 쿼리 및 부정/품번/범위 조건 사후 정밀 검증 필터링 (2차 안전망)
    if (nonLangTokens.length > 1 ||
        nonLangTokens.any(_isFilterOrNegativeToken)) {
      merged.retainWhere((item) => matchesAllQueryTokens(item, nonLangTokens));
    }

    if (isRandom && randomSeed != null) {
      final seed = randomSeed;
      // random 검색일 때는 일관된 seed 정렬 유지
      merged.sort((a, b) {
        final scoreA = (a.id() * seed) - (a.id() * seed).floor();
        final scoreB = (b.id() * seed) - (b.id() * seed).floor();
        return scoreB.compareTo(scoreA);
      });
    } else if (effectiveSortMode != SearchSortMode.latest && pureQueryWithoutLang.isEmpty) {
      // Hitomi 공식 CDN 인기순 인덱스(1위~50위) 순서를 100% 보존
    } else if (effectiveSortMode != SearchSortMode.latest) {
      // 태그 검색어 등과 함께 사용된 인기순은 Population 인기도 랭킹으로 정렬
      await Population.ensureLoaded();
      Population.sortByPopulation(merged);
    } else {
      merged.sort((a, b) => b.id().compareTo(a.id()));
    }

    return merged;
  }

  /// 해당 작품이 로컬 DB/E-Hentai에 없는 순수 Hitomi 독점작인지 여부를 판별합니다.
  static bool isHitomiOnly(QueryResult item) {
    final res = item.result;
    if (res['is_common'] == true || res['source'] == 'common' || res['source'] == 'ehentai' || res['source'] == 'violet') {
      return false;
    }
    if (res['EHash'] != null) return false;
    final cached = _sessionBadgeCache[item.id()];
    if (cached == 'common' || cached == 'ehentai' || cached == 'violet') return false;
    if (cached == 'hitomi_only' || res['is_hitomi_only'] == true || res['source'] == 'hitomi_only') {
      return true;
    }
    // 명시적으로 검증되지 않은 작품은 Hitomi 단독작으로 노출하지 않음 (안전 가드)
    return false;
  }

  /// 해당 작품이 E-Hentai/Violet과 Hitomi 양쪽에 모두 존재하는 공통 작품인지 여부를 판별합니다.
  static bool isCommon(QueryResult item) {
    final res = item.result;
    if (res['is_common'] == true || res['source'] == 'common') return true;
    final cached = _sessionBadgeCache[item.id()];
    if (cached == 'common') return true;
    if (cached == 'hitomi_only' || res['is_hitomi_only'] == true || res['source'] == 'hitomi_only') {
      return false;
    }
    final hasEHash = res['EHash'] != null;
    final hasHitomi = res['ExistOnHitomi'] == 1 || res['source'] == 'hitomi';
    if (hasEHash && hasHitomi) return true;
    if ((res['source'] == null || res['source'] == '') &&
        res['ExistOnHitomi'] == 1 &&
        res['is_hitomi_only'] != true) {
      return true;
    }
    return false;
  }

  /// 작품(QueryResult)이 주어진 비언어 검색 토큰들(태그, 작가, 시리즈 등)을 모두 만족하는지 정밀 검증합니다.
  static bool matchesAllQueryTokens(QueryResult item, List<String> tokens) {
    if (tokens.isEmpty) return true;

    final rawTags = item.tags()?.toString() ?? '';
    final tagList = rawTags
        .split('|')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty && e != 'n/a')
        .toList();

    final rawArtists = item.artists()?.toString() ?? '';
    final artistList = rawArtists
        .split('|')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty && e != 'n/a')
        .toList();

    final rawGroups = item.groups()?.toString() ?? '';
    final groupList = rawGroups
        .split('|')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty && e != 'n/a')
        .toList();

    final rawSeries = item.series()?.toString() ?? '';
    final seriesList = rawSeries
        .split('|')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty && e != 'n/a')
        .toList();

    final rawCharacters = item.characters()?.toString() ?? '';
    final characterList = rawCharacters
        .split('|')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty && e != 'n/a')
        .toList();

    final title = (item.title() ?? '').toString().toLowerCase();

    for (final rawTok in tokens) {
      var tok = rawTok.replaceAll(RegExp(r'[\(\)]'), '').trim();
      if (tok.isEmpty) continue;

      bool negative = false;
      if (tok.startsWith('-')) {
        negative = true;
        tok = tok.substring(1).trim();
        if (tok.isEmpty) continue;
      }

      final lowerTok = tok.toLowerCase();
      final rawId = item.result['Id'];
      final itemId = rawId is num
          ? rawId.toInt()
          : int.tryParse(rawId?.toString() ?? '');

      if (lowerTok.startsWith('id:') ||
          RegExp(r'^id(?:!=|>=|<=|==|>|<|=)\d+$').hasMatch(lowerTok)) {
        final matched =
            itemId != null && Settings.matchesIdRule(itemId, lowerTok);
        if (negative) {
          if (matched) return false;
        } else {
          if (!matched) return false;
        }
        continue;
      }

      if (negative && int.tryParse(lowerTok) != null) {
        final targetId = int.parse(lowerTok);
        if (itemId != null && itemId == targetId) return false;
        continue;
      }

      if (RegExp(r'^page(?:>=|<=|==|>|<|=|:)').hasMatch(lowerTok)) {
        final rawFiles = item.files();
        final pages = rawFiles is num
            ? rawFiles.toInt()
            : int.tryParse(rawFiles?.toString() ?? '');
        if (pages == null) continue;
        bool matched = true;
        final cmp = RegExp(r'^page(>=|<=|==|>|<|=)(\d+)$').firstMatch(lowerTok);
        final rng = RegExp(r'^page:(\d*)~(\d*)$').firstMatch(lowerTok);
        final exact = RegExp(r'^page:(\d+)$').firstMatch(lowerTok);
        if (cmp != null) {
          final op = cmp.group(1)!;
          final v = int.parse(cmp.group(2)!);
          matched = switch (op) {
            '>' => pages > v,
            '>=' => pages >= v,
            '<' => pages < v,
            '<=' => pages <= v,
            '=' || '==' => pages == v,
            _ => true,
          };
        } else if (rng != null) {
          final minP = int.tryParse(rng.group(1) ?? '');
          final maxP = int.tryParse(rng.group(2) ?? '');
          if (minP != null && pages < minP) matched = false;
          if (maxP != null && pages > maxP) matched = false;
        } else if (exact != null) {
          matched = pages == int.parse(exact.group(1)!);
        }
        if (negative ? matched : !matched) return false;
        continue;
      }

      if (RegExp(r'^(?:date|published)(?:>=|<=|==|>|<|=|:)').hasMatch(lowerTok)) {
        continue;
      }

      final colonIdx = tok.indexOf(':');
      bool matched = false;

      if (colonIdx != -1) {
        final prefix = tok.substring(0, colonIdx).trim().toLowerCase();
        final val = tok.substring(colonIdx + 1).trim().toLowerCase();
        final valSpaced = val.replaceAll('_', ' ');

        switch (prefix) {
          case 'female':
            matched = tagList.any((t) =>
                t == 'female:$val' || t == 'female:$valSpaced');
            break;
          case 'male':
            matched = tagList.any((t) =>
                t == 'male:$val' || t == 'male:$valSpaced');
            break;
          case 'tag':
            matched = tagList.any((t) =>
                t == val ||
                t == valSpaced ||
                t == 'female:$val' ||
                t == 'female:$valSpaced' ||
                t == 'male:$val' ||
                t == 'male:$valSpaced');
            break;
          case 'artist':
            matched = artistList.any((a) => a == val || a == valSpaced);
            break;
          case 'group':
            matched = groupList.any((g) => g == val || g == valSpaced);
            break;
          case 'series':
            matched = seriesList.any((s) => s == val || s == valSpaced);
            break;
          case 'character':
            matched = characterList.any((c) => c == val || c == valSpaced);
            break;
          case 'uploader':
            final upl = (item.uploader() ?? '').toString().toLowerCase().trim();
            matched = (upl == val || upl == valSpaced);
            break;
          case 'type':
            final tp = (item.type() ?? '').toString().toLowerCase().trim();
            matched = (tp == val || tp == valSpaced);
            break;
          default:
            matched = tagList.any((t) =>
                t == '$prefix:$val' || t == '$prefix:$valSpaced');
            break;
        }
      } else {
        // 콜론이 없는 일반 단어: 태그, 제목, 작가, 시리즈 중 하나에 포함
        final val = tok.toLowerCase();
        final valSpaced = val.replaceAll('_', ' ');

        matched = tagList.any((t) =>
                t == val ||
                t == valSpaced ||
                t == 'female:$val' ||
                t == 'female:$valSpaced' ||
                t == 'male:$val' ||
                t == 'male:$valSpaced' ||
                t.contains(val) ||
                t.contains(valSpaced)) ||
            title.contains(val) ||
            title.contains(valSpaced) ||
            artistList.any((a) => a.contains(val) || a.contains(valSpaced)) ||
            seriesList.any((s) => s.contains(val) || s.contains(valSpaced));
      }

      if (negative) {
        if (matched) return false;
      } else {
        if (!matched) return false;
      }
    }

    return true;
  }
}
