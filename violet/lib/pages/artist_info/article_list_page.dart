// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:auto_animated/auto_animated.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/bookmark.dart';
import 'package:violet/model/article_list_item.dart';
import 'package:violet/pages/artist_info/artist_info_page.dart';
import 'package:violet/pages/artist_info/search_type2.dart';
import 'package:violet/pages/segment/filter_page.dart';
import 'package:violet/pages/segment/filter_page_controller.dart';
import 'package:violet/pages/segment/platform_navigator.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/style/palette.dart';
import 'package:violet/widgets/article_item/article_list_item_widget.dart';
import 'package:violet/widgets/search_bar.dart';

class ArticleListPage extends StatefulWidget {
  final List<QueryResult> cc;
  final String name;

  final String? initialLanguage;
  final String? artistName;
  final ArtistType? artistType;
  final bool isWebMode;
  final Map<String, List<QueryResult>>? initialLangCache;

  const ArticleListPage({
    super.key,
    required this.name,
    required this.cc,
    this.initialLanguage,
    this.artistName,
    this.artistType,
    this.isWebMode = true,
    this.initialLangCache,
  });

  @override
  State<ArticleListPage> createState() => _ArticleListPageState();
}

class _ArticleListPageState extends State<ArticleListPage> {
  bool _shouldReload = false;
  Widget? _cachedList;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height =
        MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top;
    final mediaQuery = MediaQuery.of(context);
    final color = Palette.themeColor;

    if (_cachedList == null || _shouldReload) {
      final list = buildList();

      _shouldReload = false;
      _cachedList = list;
    }

    return Container(
      color: color,
      child: Padding(
        // padding: EdgeInsets.all(0),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
          bottom: (mediaQuery.padding + mediaQuery.viewInsets).bottom,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Card(
              elevation: 5,
              color: Palette.themeColor,
              child: SizedBox(
                width: width - 16,
                height:
                    height -
                    16 -
                    (mediaQuery.padding + mediaQuery.viewInsets).bottom,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                  child: CustomScrollView(
                    controller: _scrollControllers[nowType],
                    physics: const BouncingScrollPhysics(),
                    slivers: <Widget>[
                      SliverPersistentHeader(
                        floating: true,
                        delegate: AnimatedOpacitySliver(
                          searchBar: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: Stack(
                              children: <Widget>[_align(), _title()],
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _languageSelector(),
                      ),
                      if (_isLoadingLang)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 48.0),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      else
                        _cachedList!,
                      if (_isLoadingMore)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 16.0),
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _align() {
    return Align(
      alignment: Alignment.centerRight,
      child: Hero(
        tag: 'searchtype2',
        child: Card(
          color: Palette.themeColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8.0)),
          ),
          elevation: 100,
          clipBehavior: Clip.antiAliasWithSaveLayer,
          child: InkWell(
            child: const SizedBox(
              height: 48,
              width: 48,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(MdiIcons.formatListText, color: Colors.grey),
                ],
              ),
            ),
            onTap: () async {
              PlatformNavigator.navigateOption(
                context,
                SearchType2(nowType: nowType),
              ).then((value) async {
                if (value == null) return;
                nowType = value;
                await Future.delayed(const Duration(milliseconds: 50), () {
                  _shouldReload = true;
                  setState(() {
                    _shouldReload = true;
                  });
                });
              });
            },
            onLongPress: () {
              PlatformNavigator.navigateFade(
                context,
                Provider<FilterController>.value(
                  value: _filterController,
                  child: FilterPage(queryResult: _currentBaseSource()),
                ),
              ).then((value) async {
                _applyFilter();
                _shouldReload = true;
                setState(() {
                  _shouldReload = true;
                  key = ObjectKey(const Uuid().v4());
                });
              });
            },
          ),
        ),
      ),
    );
  }

  Widget _title() {
    final count = filter().length;
    return Padding(
      padding: const EdgeInsets.only(top: 24, left: 12, right: 56),
      child: Text(
        '${widget.name} ($count)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
    );
  }

  ObjectKey key = ObjectKey(const Uuid().v4());

  final FilterController _filterController = FilterController(
    heroKey: 'searchtype2',
  );
  List<QueryResult> filterResult = [];

  bool isFilterUsed = false;

  void _applyFilter() {
    if (!_filterController.hasAnyActiveFilter &&
        !_filterController.isPopulationSort) {
      isFilterUsed = false;
      filterResult = [];
      return;
    }
    filterResult = _filterController.applyFilter(_currentBaseSource());
    isFilterUsed = true;
  }

  late String selectedLanguage;
  final Map<String, List<QueryResult>> _langArticles = {};
  final Map<String, int> _pageByLang = {};
  final Map<String, bool> _hasMoreByLang = {};
  bool _isLoadingLang = false;
  bool _isLoadingMore = false;
  static const int _pageSize = 60;

  @override
  void initState() {
    super.initState();
    selectedLanguage = widget.initialLanguage ?? 'all';
    if (widget.initialLangCache != null) {
      for (final entry in widget.initialLangCache!.entries) {
        _langArticles[entry.key] = List<QueryResult>.from(entry.value);
        _pageByLang[entry.key] = 1;
        _hasMoreByLang[entry.key] = widget.artistName != null;
      }
    }
    if (widget.artistName != null) {
      final existing = _langArticles[selectedLanguage] ?? <QueryResult>[];
      final seen = existing.map((e) => e.id()).toSet();
      final merged = List<QueryResult>.from(existing);
      for (final item in widget.cc) {
        if (!seen.contains(item.id())) {
          seen.add(item.id());
          merged.add(item);
        }
      }
      merged.sort((a, b) => b.id().compareTo(a.id()));
      _langArticles[selectedLanguage] = merged;
      _pageByLang.putIfAbsent(selectedLanguage, () => 1);
      _hasMoreByLang.putIfAbsent(selectedLanguage, () => true);
    }

    for (final c in _scrollControllers) {
      c.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    for (final c in _scrollControllers) {
      c.removeListener(_onScroll);
      c.dispose();
    }
    super.dispose();
  }

  void _onScroll() {
    if (widget.artistName == null || widget.artistType == null) return;
    if (_isLoadingLang || _isLoadingMore) return;
    if (!(_hasMoreByLang[selectedLanguage] ?? false)) return;
    final controller = _scrollControllers[nowType];
    if (!controller.hasClients) return;
    if (controller.position.pixels >=
        controller.position.maxScrollExtent - 400) {
      _loadMoreForCurrentLanguage();
    }
  }

  Future<List<QueryResult>> _fetchArtistPage(String lang, int page) async {
    if (widget.artistName == null || widget.artistType == null) {
      return const [];
    }
    if (widget.isWebMode) {
      return await HybridLoader.fetchArtistArticlesHybrid(
        name: widget.artistName!,
        type: widget.artistType!.name,
        page: page,
        pageSize: _pageSize,
        language: lang,
      );
    }
    final token =
        '${widget.artistType!.name}:${widget.artistName!.replaceAll(' ', '_')}';
    final langToken = lang != 'all' ? 'language:$lang' : '';
    final sql = translate2query(
      '$token $langToken ${Settings.includeTags.value} ${Settings.serializedExcludeTags}'
          .trim(),
    );
    final offset = (page - 1) * _pageSize;
    final qm = await QueryManager.query(
      '$sql ORDER BY Id DESC LIMIT $_pageSize OFFSET $offset',
    );
    return qm.results ?? const [];
  }

  Future<void> _selectLanguage(String lang) async {
    if (selectedLanguage == lang && !_isLoadingLang) return;
    if (widget.artistName == null ||
        widget.artistType == null ||
        _langArticles.containsKey(lang)) {
      setState(() {
        selectedLanguage = lang;
        if (isFilterUsed) _applyFilter();
        _shouldReload = true;
        key = ObjectKey(const Uuid().v4());
      });
      return;
    }

    setState(() {
      selectedLanguage = lang;
      _isLoadingLang = true;
    });

    try {
      final fetched = await _fetchArtistPage(lang, 1);
      _langArticles[lang] = fetched;
      _pageByLang[lang] = 1;
      _hasMoreByLang[lang] = fetched.isNotEmpty;
    } catch (_) {
      _langArticles[lang] = <QueryResult>[];
      _pageByLang[lang] = 1;
      _hasMoreByLang[lang] = false;
    }

    if (!mounted) return;
    setState(() {
      _isLoadingLang = false;
      if (isFilterUsed) _applyFilter();
      _shouldReload = true;
      key = ObjectKey(const Uuid().v4());
    });
  }

  Future<void> _loadMoreForCurrentLanguage() async {
    if (_isLoadingMore || _isLoadingLang) return;
    final lang = selectedLanguage;
    if (!(_hasMoreByLang[lang] ?? false)) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final nextPage = (_pageByLang[lang] ?? 1) + 1;
      final fetched = await _fetchArtistPage(lang, nextPage);
      _pageByLang[lang] = nextPage;

      final current = _langArticles[lang] ?? <QueryResult>[];
      final existingIds = current.map((e) => e.id()).toSet();
      final added =
          fetched.where((e) => !existingIds.contains(e.id())).toList();

      if (added.isEmpty) {
        _hasMoreByLang[lang] = false;
      } else {
        current.addAll(added);
        current.sort((a, b) => b.id().compareTo(a.id()));
        _langArticles[lang] = current;
      }
    } catch (_) {
      _hasMoreByLang[lang] = false;
    }

    if (!mounted) return;
    setState(() {
      _isLoadingMore = false;
      if (isFilterUsed) _applyFilter();
      _shouldReload = true;
    });
  }

  List<QueryResult> _currentBaseSource() {
    if (widget.artistName != null &&
        _langArticles.containsKey(selectedLanguage)) {
      return _langArticles[selectedLanguage]!;
    }
    return widget.cc;
  }

  Widget _languageSelector() {
    final langs = [
      ('all', '전체'),
      ('korean', '한국어'),
      ('japanese', '일본어'),
      ('english', '영어'),
      ('chinese', '중국어'),
    ];

    return Padding(
      padding: const EdgeInsets.only(left: 12.0, right: 12.0, bottom: 8.0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: langs.map((item) {
            final isSelected = selectedLanguage == item.$1;
            return Padding(
              padding: const EdgeInsets.only(right: 6.0),
              child: ChoiceChip(
                label: Text(
                  item.$2,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? Colors.white : null,
                  ),
                ),
                selected: isSelected,
                selectedColor: Settings.majorColor.value,
                onSelected: (selected) {
                  if (selected) {
                    _selectLanguage(item.$1);
                  }
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  List<QueryResult> filter() {
    final base = !isFilterUsed ? _currentBaseSource() : filterResult;
    final langFiltered = selectedLanguage == 'all'
        ? base
        : ArtistInfoPage.filterByLanguage(base, selectedLanguage);
    return langFiltered.where((e) => !Settings.isExcluded(e)).toList();
  }

  int nowType = 0;

  final List<ScrollController> _scrollControllers = Iterable.generate(
    5,
    (i) => ScrollController(),
  ).toList();

  Widget buildList() {
    final items = filter();
    final columnCount =
        MediaQuery.of(context).orientation == Orientation.landscape ? 4 : 3;
    final mm = nowType == 0 ? columnCount : 2;
    final windowWidth = MediaQuery.of(context).size.width;
    switch (nowType) {
      case 0:
      case 1:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          sliver: LiveSliverGrid(
            key: key,
            controller: _scrollControllers[nowType],
            showItemInterval: const Duration(milliseconds: 50),
            showItemDuration: const Duration(milliseconds: 150),
            visibleFraction: 0.001,
            itemCount: items.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: mm,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 3 / 4,
            ),
            itemBuilder: (context, index, animation) {
              return FadeTransition(
                opacity: Tween<double>(begin: 0, end: 1).animate(animation),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.1),
                    end: Offset.zero,
                  ).animate(animation),
                  child: Padding(
                    padding: EdgeInsets.zero,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        child: Provider<ArticleListItem>.value(
                          value: ArticleListItem.fromArticleListItem(
                            queryResult: items[index],
                            showDetail: false,
                            addBottomPadding: false,
                            width: (windowWidth - 4.0) / mm,
                            thumbnailTag: const Uuid().v4(),
                            usableTabList: items,
                          ),
                          child: const ArticleListItemWidget(),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );

      case 2:
      case 3:
      case 4:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          sliver: LiveSliverList(
            key: key,
            controller: _scrollControllers[nowType],
            itemCount: items.length,
            itemBuilder: (context, index, animation) {
              return Align(
                alignment: Alignment.center,
                child: Provider<ArticleListItem>.value(
                  value: ArticleListItem.fromArticleListItem(
                    addBottomPadding: true,
                    showDetail: nowType >= 3,
                    showUltra: nowType == 4,
                    queryResult: items[index],
                    width: windowWidth - 4.0,
                    thumbnailTag: const Uuid().v4(),
                    usableTabList: items,
                  ),
                  child: const ArticleListItemWidget(),
                ),
              );
            },
          ),
        );

      default:
        return const Center(child: Text('Error :('));
    }
  }
}
