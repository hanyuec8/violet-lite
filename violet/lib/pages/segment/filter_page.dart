// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html_unescape/html_unescape_small.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';
import 'package:violet/component/hangul_auto_restorer.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/database/query.dart';
import 'package:violet/locale/locale.dart' as trans;
import 'package:violet/pages/segment/card_panel.dart';
import 'package:violet/pages/segment/filter_page_controller.dart';
import 'package:violet/settings/settings.dart';

class FilterPage extends StatefulWidget {
  final List<QueryResult> queryResult;

  const FilterPage({super.key, required this.queryResult});

  @override
  State<FilterPage> createState() => _FilterPageState();
}

class _FilterPageState extends State<FilterPage> {
  late FilterController c;

  final _tagSearchController = TextEditingController();
  final _localQueryController = TextEditingController();
  final _minPageController = TextEditingController();
  final _maxPageController = TextEditingController();

  final _tags = <(String, String, int)>[];
  final _groupCount = <String, int>{};
  final _groups = <(String, int)>[];

  bool _initOnce = false;
  bool _excludeTapMode = false;
  bool _showAdvancedPanel = false;
  int _matchedCount = 0;

  void _initTagPad() {
    final tags = <String, int>{};
    for (final element in widget.queryResult) {
      if (element.tags() != null) {
        for (final raw in element.tags().toString().split('|')) {
          final tag = raw.trim();
          if (tag.isEmpty) continue;
          tags[tag] = (tags[tag] ?? 0) + 1;
        }
      }
    }

    _groupCount['tag'] = 0;
    _groupCount['female'] = 0;
    _groupCount['male'] = 0;

    tags.forEach((key, value) {
      var group = 'tag';
      var name = key;
      if (key.startsWith('female:') || key.startsWith('male:')) {
        final idx = key.indexOf(':');
        group = key.substring(0, idx);
        name = key.substring(idx + 1);
      }
      _groupCount[group] = (_groupCount[group] ?? 0) + 1;
      _tags.add((group, name, value));
      final tagKey = '$group|$name';
      c.tagStates.putIfAbsent(tagKey, () => false);
      c.excludedTagStates.putIfAbsent(tagKey, () => false);
    });

    c.groupStates.putIfAbsent('tag', () => false);
    c.groupStates.putIfAbsent('female', () => false);
    c.groupStates.putIfAbsent('male', () => false);

    _appendGroup('language', 'Language');
    _appendGroup('character', 'Characters');
    _appendGroup('series', 'Series');
    _appendGroup('artist', 'Artists');
    _appendGroup('group', 'Groups');
    _appendGroup('class', 'Class');
    _appendGroup('type', 'Type');
    _appendGroup('uploader', 'Uploader');

    _groupCount.forEach((key, value) {
      if (value > 0) {
        _groups.add((key, value));
      }
    });
    _groups.sort((a, b) => b.$2.compareTo(a.$2));
    _tags.sort((a, b) => b.$3.compareTo(a.$3));

    // 진입 직후 빈 화면 방지를 위해 활성 그룹이 없으면 주요 태그 그룹 자동 활성화
    if (!c.groupStates.values.any((v) => v)) {
      for (final defaultGroup in ['female', 'male', 'tag', 'artist', 'series']) {
        if ((_groupCount[defaultGroup] ?? 0) > 0) {
          c.groupStates[defaultGroup] = true;
        }
      }
      if (!c.groupStates.values.any((v) => v) && _groups.isNotEmpty) {
        c.groupStates[_groups.first.$1] = true;
      }
    }
  }

  void _appendGroup(String group, String column) {
    c.groupStates.putIfAbsent(group, () => false);
    final counts = <String, int>{};
    for (final element in widget.queryResult) {
      final raw = element.result[column];
      if (raw == null) continue;
      for (final token in raw.toString().split('|')) {
        final trimmed = token.trim();
        if (trimmed.isEmpty) continue;
        counts[trimmed] = (counts[trimmed] ?? 0) + 1;
      }
    }
    _groupCount[group] = (_groupCount[group] ?? 0) + counts.length;
    counts.forEach((key, value) {
      _tags.add((group, key, value));
      final tagKey = '$group|$key';
      c.tagStates.putIfAbsent(tagKey, () => false);
      c.excludedTagStates.putIfAbsent(tagKey, () => false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initOnce) {
      _initOnce = true;
      c = Provider.of<FilterController>(context, listen: false);
      _minPageController.text = c.minPages?.toString() ?? '';
      _maxPageController.text = c.maxPages?.toString() ?? '';
      _localQueryController.text = c.localQuery;
      _showAdvancedPanel =
          c.minPages != null ||
          c.maxPages != null ||
          c.localQuery.trim().isNotEmpty;
      _initTagPad();
      _recalculateMatchCount();
    }
  }

  @override
  void dispose() {
    _tagSearchController.dispose();
    _localQueryController.dispose();
    _minPageController.dispose();
    _maxPageController.dispose();
    super.dispose();
  }

  void _recalculateMatchCount() {
    _matchedCount = c.applyFilter(widget.queryResult).length;
  }

  void _handleTagTap(String key) {
    setState(() {
      if (_excludeTapMode) {
        c.toggleExcludeTag(key);
      } else {
        c.cycleTagState(key);
      }
      if (_tagSearchController.text.isNotEmpty) {
        _tagSearchController.clear();
      }
      _recalculateMatchCount();
    });
  }

  void _handleTagLongPress(String key) {
    setState(() {
      c.toggleExcludeTag(key);
      if (_tagSearchController.text.isNotEmpty) {
        _tagSearchController.clear();
      }
      _recalculateMatchCount();
    });
  }

  void _resetAllFilters() {
    setState(() {
      c.resetAll();
      _minPageController.clear();
      _maxPageController.clear();
      _localQueryController.clear();
      _recalculateMatchCount();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Settings.themeWhat.value;
    final accent = Settings.majorColor.value;

    return CardPanel.build(
      context,
      heroTag: null,
      enableBackgroundColor: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          children: <Widget>[
            _buildHeaderBar(isDark, accent),
            _buildActiveSummaryBar(isDark, accent),
            _buildTagSearchRow(isDark, accent),
            if (_showAdvancedPanel) _buildAdvancedPanel(isDark, accent),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                physics: const BouncingScrollPhysics(),
                children: [_buildTagsPanel()],
              ),
            ),
            const Divider(height: 8),
            _buildGroupSelectPanel(),
            const SizedBox(height: 4),
            _buildBatchAndOptionControls(accent),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBar(bool isDark, Color accent) {
    final total = widget.queryResult.length;
    final includeCount = c.includedTagKeys.length;
    final excludeCount = c.excludedTagKeys.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '매칭 $_matchedCount / $total개',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    if (includeCount > 0 || excludeCount > 0) ...[
                      const SizedBox(width: 8),
                      if (includeCount > 0)
                        _buildBadge('+$includeCount', accent),
                      if (includeCount > 0 && excludeCount > 0)
                        const SizedBox(width: 4),
                      if (excludeCount > 0)
                        _buildBadge('-$excludeCount', Colors.redAccent),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _excludeTapMode
                      ? '제외 선택 모드: 탭으로 즉시 제외(-)'
                      : '탭: 포함(+) -> 제외(-) -> 해제 / 길게: 즉시 제외(-)',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.grey[400] : Colors.grey[700],
                  ),
                ),
              ],
            ),
          ),
          if (c.hasAnyActiveFilter)
            TextButton(
              onPressed: _resetAllFilters,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: Colors.redAccent,
              ),
              child: const Text('초기화', style: TextStyle(fontSize: 13)),
            ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('적용', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildActiveSummaryBar(bool isDark, Color accent) {
    final includes = c.includedTagKeys;
    final excludes = c.excludedTagKeys;
    if (includes.isEmpty && excludes.isEmpty) {
      return const SizedBox.shrink();
    }

    Widget buildSelectedChip(String key, bool isExclude) {
      final sepIdx = key.indexOf('|');
      final group = sepIdx > 0 ? key.substring(0, sepIdx) : 'tag';
      final rawName = sepIdx > 0 ? key.substring(sepIdx + 1) : key;
      var displayName = rawName;
      if (Settings.translateTags.value) {
        displayName = TagTranslate.ofAny(rawName).split(':').last.split('|').first;
      }
      displayName = HtmlUnescape().convert(displayName);
      final chipColor = isExclude ? Colors.redAccent : accent;

      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          onTap: () {
            setState(() {
              c.setTagState(key, TagFilterState.none);
              _recalculateMatchCount();
            });
          },
          onLongPress: () => _handleTagLongPress(key),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: chipColor, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isExclude ? Icons.block : Icons.check,
                  size: 13,
                  color: chipColor,
                ),
                const SizedBox(width: 4),
                Text(
                  '$group:$displayName',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    decoration: isExclude ? TextDecoration.lineThrough : null,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.close, size: 13, color: chipColor),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ...includes.map((k) => buildSelectedChip(k, false)),
            ...excludes.map((k) => buildSelectedChip(k, true)),
          ],
        ),
      ),
    );
  }

  Widget _buildTagSearchRow(bool isDark, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _tagSearchController,
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '폴더 내 태그·작가·시리즈 검색 (한글/영문)',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _tagSearchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _tagSearchController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: Text(
              _excludeTapMode ? '제외 선택중' : '제외 모드',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _excludeTapMode ? Colors.white : Colors.redAccent,
              ),
            ),
            selected: _excludeTapMode,
            selectedColor: Colors.redAccent,
            checkmarkColor: Colors.white,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => setState(() => _excludeTapMode = v),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '페이지 수 및 고급 쿼리 필터',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                setState(() => _showAdvancedPanel = !_showAdvancedPanel),
            icon: Icon(
              _showAdvancedPanel ? Icons.tune : Icons.tune_outlined,
              size: 20,
              color: (c.minPages != null ||
                      c.maxPages != null ||
                      c.localQuery.trim().isNotEmpty)
                  ? accent
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  void _applyPresetPages(int? minP, int? maxP) {
    setState(() {
      if (c.minPages == minP && c.maxPages == maxP) {
        c.minPages = null;
        c.maxPages = null;
      } else {
        c.minPages = minP;
        c.maxPages = maxP;
      }
      _minPageController.text = c.minPages?.toString() ?? '';
      _maxPageController.text = c.maxPages?.toString() ?? '';
      _recalculateMatchCount();
    });
  }

  Widget _buildAdvancedPanel(bool isDark, Color accent) {
    const presets = <(String, int?, int?)>[
      ('단편 <=30p', null, 30),
      ('중편 31~80p', 31, 80),
      ('장편 80p+', 80, null),
      ('초장편 150p+', 150, null),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(MdiIcons.bookOpenPageVariantOutline, size: 16, color: accent),
              const SizedBox(width: 6),
              const Text(
                '페이지 수 / 고급 검색 필터',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (c.minPages != null ||
                  c.maxPages != null ||
                  c.localQuery.trim().isNotEmpty)
                InkWell(
                  onTap: () {
                    setState(() {
                      c.resetPageFilter();
                      c.localQuery = '';
                      _minPageController.clear();
                      _maxPageController.clear();
                      _localQueryController.clear();
                      _recalculateMatchCount();
                    });
                  },
                  child: Text(
                    '조건 지우기',
                    style: TextStyle(fontSize: 12, color: accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _minPageController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '최소 p',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        c.minPages = int.tryParse(v.trim());
                        _recalculateMatchCount();
                      });
                    },
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('-'),
              ),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _maxPageController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '최대 p',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        c.maxPages = int.tryParse(v.trim());
                        _recalculateMatchCount();
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: presets.map((p) {
                final selected = c.minPages == p.$2 && c.maxPages == p.$3;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(p.$1, style: const TextStyle(fontSize: 11)),
                    selected: selected,
                    selectedColor: accent.withValues(alpha: 0.25),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _applyPresetPages(p.$2, p.$3),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 34,
            child: TextField(
              controller: _localQueryController,
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: '고급 쿼리 (예: 제목 키워드, -female:태그, page>100)',
                suffixIcon: _localQueryController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _localQueryController.clear();
                          setState(() {
                            c.localQuery = '';
                            _recalculateMatchCount();
                          });
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              onChanged: (str) {
                setState(() {
                  c.localQuery = str;
                  _recalculateMatchCount();
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTagsPanel() {
    final rawQ = _tagSearchController.text.trim();
    final q = rawQ.toLowerCase().replaceAll('_', ' ');
    final restoredQ = Settings.enableHangulTypoRestore.value && rawQ.isNotEmpty
        ? HangulAutoRestorer.tryRestoreKoreanWord(rawQ)?.toLowerCase()
        : null;

    final hasGroupSelection = c.groupStates.values.any((v) => v);
    final candidates = _tags.where((element) {
      final key = '${element.$1}|${element.$2}';
      final state = c.getTagState(key);

      if (q.isNotEmpty) {
        final fullName =
            '${element.$1}:${element.$2}'.toLowerCase().replaceAll('_', ' ');
        final rawName = element.$2.toLowerCase().replaceAll('_', ' ');
        if (fullName.contains(q) || rawName.contains(q)) return true;

        final translated =
            TagTranslate.ofAny(element.$2).toLowerCase().replaceAll('_', ' ');
        if (translated.contains(q)) return true;
        if (restoredQ != null && translated.contains(restoredQ)) return true;
        return false;
      }

      if (state != TagFilterState.none) return true;
      if (!hasGroupSelection) return true;
      return c.groupStates[element.$1] ?? false;
    }).toList();

    // 선택(포함/제외)된 태그를 최상단으로 유지하고 나머지는 빈도순 정렬 유지
    candidates.sort((a, b) {
      final sa = c.getTagState('${a.$1}|${a.$2}');
      final sb = c.getTagState('${b.$1}|${b.$2}');
      final activeA = sa != TagFilterState.none ? 1 : 0;
      final activeB = sb != TagFilterState.none ? 1 : 0;
      if (activeA != activeB) return activeB.compareTo(activeA);
      return b.$3.compareTo(a.$3);
    });

    final limit = q.isNotEmpty ? 200 : 120;
    final visible = candidates.take(limit).toList();

    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            q.isNotEmpty
                ? '폴더 내 일치하는 태그가 없습니다.'
                : '하단에서 표시할 태그 그룹을 선택해 주세요.',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
      );
    }

    final spacing = (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        ? 4.0
        : -5.0;
    final runSpacing =
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            ? 4.0
            : -10.0;

    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      children: visible.map((element) {
        final key = '${element.$1}|${element.$2}';
        return _TagFilterChip(
          state: c.getTagState(key),
          group: element.$1,
          name: element.$2,
          count: element.$3,
          onTap: () => _handleTagTap(key),
          onLongPress: () => _handleTagLongPress(key),
        );
      }).toList(),
    );
  }

  Widget _buildGroupSelectPanel() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _groups.map((element) {
          final group = element.$1;
          final count = element.$2;
          final selected = c.groupStates[group] ?? false;
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _GroupToggleChip(
              group: group,
              count: count,
              selected: selected,
              onTap: () {
                setState(() {
                  c.groupStates[group] = !selected;
                });
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBatchAndOptionControls(Color accent) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4.0,
      runSpacing: -8.0,
      children: <Widget>[
        ActionChip(
          label: Text(
            trans.Translations.instance!.trans('deselectall'),
            style: const TextStyle(fontSize: 12),
          ),
          visualDensity: VisualDensity.compact,
          onPressed: () {
            setState(() {
              c.clearTags();
              _recalculateMatchCount();
            });
          },
        ),
        FilterChip(
          label: Text(
            c.isOr ? 'OR (하나라도 포함)' : 'AND (모두 포함)',
            style: const TextStyle(fontSize: 12),
          ),
          selected: c.isOr,
          selectedColor: accent.withValues(alpha: 0.25),
          visualDensity: VisualDensity.compact,
          onSelected: (bool value) {
            setState(() {
              c.isOr = value;
              _recalculateMatchCount();
            });
          },
        ),
        FilterChip(
          label: const Text('인기순 정렬', style: TextStyle(fontSize: 12)),
          selected: c.isPopulationSort,
          selectedColor: accent.withValues(alpha: 0.25),
          visualDensity: VisualDensity.compact,
          onSelected: (bool value) {
            setState(() {
              c.isPopulationSort = value;
            });
          },
        ),
      ],
    );
  }
}

Color _groupBaseColor(String group) {
  switch (group) {
    case 'female':
      return Colors.pink;
    case 'male':
      return Colors.blue;
    case 'language':
      return Colors.teal;
    case 'series':
      return Colors.cyan;
    case 'artist':
    case 'group':
      return Colors.green.shade700;
    case 'type':
      return Colors.orange;
    default:
      return Colors.grey.shade700;
  }
}

Widget _groupAvatarIcon(String group) {
  switch (group) {
    case 'female':
      return const Icon(MdiIcons.genderFemale, size: 16.0, color: Colors.white);
    case 'male':
      return const Icon(MdiIcons.genderMale, size: 16.0, color: Colors.white);
    case 'language':
      return const Icon(Icons.language, size: 16.0, color: Colors.white);
    case 'artist':
      return const Icon(MdiIcons.account, size: 16.0, color: Colors.white);
    case 'group':
      return const Icon(MdiIcons.accountGroup, size: 14.0, color: Colors.white);
    case 'type':
      return const Icon(
        MdiIcons.bookOpenPageVariant,
        size: 14.0,
        color: Colors.white,
      );
    case 'series':
      return const Icon(MdiIcons.notebook, size: 14.0, color: Colors.white);
    default:
      return Text(
        group[0].toUpperCase(),
        style: const TextStyle(color: Colors.white, fontSize: 12),
      );
  }
}

class _GroupToggleChip extends StatelessWidget {
  final String group;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _GroupToggleChip({
    required this.group,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = _groupBaseColor(group);
    return FilterChip(
      selected: selected,
      showCheckmark: true,
      checkmarkColor: Colors.white,
      selectedColor: baseColor,
      backgroundColor: baseColor.withValues(alpha: 0.35),
      visualDensity: VisualDensity.compact,
      avatar: _groupAvatarIcon(group),
      label: Text(
        '$group ($count)',
        style: const TextStyle(color: Colors.white, fontSize: 11.5),
      ),
      onSelected: (_) => onTap(),
    );
  }
}

class _TagFilterChip extends StatelessWidget {
  final TagFilterState state;
  final String group;
  final String name;
  final int count;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _TagFilterChip({
    required this.state,
    required this.group,
    required this.name,
    required this.count,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    var tagDisplayed = name;
    if (Settings.translateTags.value) {
      tagDisplayed =
          TagTranslate.ofAny(tagDisplayed).split(':').last.split('|').first;
    }
    final displayText = count > 0
        ? '${HtmlUnescape().convert(tagDisplayed)} ($count)'
        : HtmlUnescape().convert(tagDisplayed);

    final baseColor = _groupBaseColor(group);
    final isInclude = state == TagFilterState.include;
    final isExclude = state == TagFilterState.exclude;

    final Color bgColor;
    final Color borderColor;
    if (isExclude) {
      bgColor = Colors.red.shade800;
      borderColor = Colors.redAccent;
    } else if (isInclude) {
      bgColor = baseColor;
      borderColor = Colors.lightGreenAccent;
    } else {
      bgColor = baseColor.withValues(alpha: 0.72);
      borderColor = Colors.transparent;
    }

    final Widget avatarChild;
    if (isExclude) {
      avatarChild = const Icon(Icons.block, size: 15.0, color: Colors.white);
    } else if (isInclude) {
      avatarChild = const Icon(Icons.check, size: 15.0, color: Colors.white);
    } else {
      avatarChild = _groupAvatarIcon(group);
    }

    return Transform.scale(
      scale: 0.90,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ActionChip(
          onPressed: onTap,
          backgroundColor: bgColor,
          side: BorderSide(
            color: borderColor,
            width: state == TagFilterState.none ? 0.0 : 1.8,
          ),
          elevation: state == TagFilterState.none ? 2.0 : 5.0,
          labelPadding: const EdgeInsets.symmetric(horizontal: 4.0),
          padding: const EdgeInsets.all(4.0),
          avatar: CircleAvatar(
            backgroundColor: isExclude
                ? Colors.red.shade900
                : isInclude
                    ? Colors.green.shade700
                    : Colors.black26,
            child: avatarChild,
          ),
          label: Text(
            isExclude ? '- $displayText' : (isInclude ? '+ $displayText' : displayText),
            style: TextStyle(
              color: Colors.white,
              fontWeight: state == TagFilterState.none
                  ? FontWeight.normal
                  : FontWeight.bold,
              decoration: isExclude ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }
}
