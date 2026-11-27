// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:violet/component/hitomi/population.dart';
import 'package:violet/component/local_article_filter.dart';
import 'package:violet/database/query.dart';
import 'package:violet/settings/settings.dart';

enum TagFilterState { none, include, exclude }

class FilterController {
  var isOr = false;
  var isSearch = false;
  var isPopulationSort = false;
  String heroKey;

  var tagStates = <String, bool>{};
  var excludedTagStates = <String, bool>{};
  var groupStates = <String, bool>{};

  int? minPages;
  int? maxPages;
  String localQuery = '';

  TagFilterState getTagState(String key) {
    if (excludedTagStates[key] ?? false) return TagFilterState.exclude;
    if (tagStates[key] ?? false) return TagFilterState.include;
    return TagFilterState.none;
  }

  void setTagState(String key, TagFilterState state) {
    switch (state) {
      case TagFilterState.none:
        tagStates[key] = false;
        excludedTagStates[key] = false;
        break;
      case TagFilterState.include:
        tagStates[key] = true;
        excludedTagStates[key] = false;
        break;
      case TagFilterState.exclude:
        tagStates[key] = false;
        excludedTagStates[key] = true;
        break;
    }
  }

  TagFilterState cycleTagState(String key) {
    final next = switch (getTagState(key)) {
      TagFilterState.none => TagFilterState.include,
      TagFilterState.include => TagFilterState.exclude,
      TagFilterState.exclude => TagFilterState.none,
    };
    setTagState(key, next);
    return next;
  }

  TagFilterState toggleExcludeTag(String key) {
    final next = getTagState(key) == TagFilterState.exclude
        ? TagFilterState.none
        : TagFilterState.exclude;
    setTagState(key, next);
    return next;
  }

  List<String> get includedTagKeys =>
      tagStates.entries.where((e) => e.value).map((e) => e.key).toList();

  List<String> get excludedTagKeys => excludedTagStates.entries
      .where((e) => e.value && !(tagStates[e.key] ?? false))
      .map((e) => e.key)
      .toList();

  int get activeTagFilterCount =>
      includedTagKeys.length + excludedTagKeys.length;

  int get activeFilterCount =>
      activeTagFilterCount +
      ((minPages != null || maxPages != null) ? 1 : 0) +
      (localQuery.trim().isNotEmpty ? 1 : 0);

  bool get hasActivePageFilter =>
      minPages != null ||
      maxPages != null ||
      RegExp(r'(?:^|\s)-?page(?:>=|<=|==|>|<|=|:)', caseSensitive: false)
          .hasMatch(localQuery);

  bool get hasAnyActiveFilter =>
      includedTagKeys.isNotEmpty ||
      excludedTagKeys.isNotEmpty ||
      minPages != null ||
      maxPages != null ||
      localQuery.trim().isNotEmpty;

  void resetPageFilter() {
    minPages = null;
    maxPages = null;
  }

  void clearTags() {
    for (final key in tagStates.keys.toList()) {
      tagStates[key] = false;
    }
    for (final key in excludedTagStates.keys.toList()) {
      excludedTagStates[key] = false;
    }
  }

  void resetAll() {
    clearTags();
    resetPageFilter();
    localQuery = '';
  }

  FilterController({this.heroKey = 'searchtype'});

  bool _matchesTag(QueryResult element, String key) {
    final sepIdx = key.indexOf('|');
    if (sepIdx <= 0 || sepIdx >= key.length - 1) return false;
    final group = key.substring(0, sepIdx);
    final targetName = key
        .substring(sepIdx + 1)
        .trim()
        .toLowerCase()
        .replaceAll(' ', '_');
    final dbColumn = prefix2Tag(group);
    if (dbColumn.isEmpty) return false;

    final rawCol = element.result[dbColumn];
    if (rawCol == null) return false;

    final colStr = rawCol.toString().trim().toLowerCase();
    if (colStr.isEmpty) return false;

    if (isSingleTag(group)) {
      return colStr.replaceAll(' ', '_') == targetName;
    }

    final tokens = colStr
        .split('|')
        .map((t) => t.trim().replaceAll(' ', '_'))
        .where((t) => t.isNotEmpty)
        .toSet();

    final fullTag = (group == 'female' || group == 'male')
        ? '$group:$targetName'
        : targetName;

    return tokens.contains(fullTag) || tokens.contains(targetName);
  }

  List<QueryResult> applyFilter(List<QueryResult> queryResult) {
    final includes = includedTagKeys;
    final excludes = excludedTagKeys;
    var result = <QueryResult>[];

    if (includes.isEmpty && excludes.isEmpty) {
      result = List<QueryResult>.from(queryResult);
    } else {
      for (final element in queryResult) {
        var matchedInclude = includes.isEmpty;
        if (includes.isNotEmpty) {
          if (isOr) {
            matchedInclude = includes.any((k) => _matchesTag(element, k));
          } else {
            matchedInclude = includes.every((k) => _matchesTag(element, k));
          }
        }
        if (!matchedInclude) continue;

        if (excludes.isNotEmpty &&
            excludes.any((k) => _matchesTag(element, k))) {
          continue;
        }
        result.add(element);
      }
    }

    if (minPages != null || maxPages != null || localQuery.trim().isNotEmpty) {
      result = LocalArticleFilter.filter(
        result,
        localQuery,
        minPages: minPages,
        maxPages: maxPages,
        restoreTypos: Settings.enableHangulTypoRestore.value,
      );
    }

    if (isPopulationSort) {
      Population.sortByPopulation(result);
    }

    return result;
  }

  static String prefix2Tag(String prefix) {
    switch (prefix) {
      case 'artist':
        return 'Artists';
      case 'group':
        return 'Groups';
      case 'language':
        return 'Language';
      case 'character':
        return 'Characters';
      case 'series':
        return 'Series';
      case 'class':
        return 'Class';
      case 'type':
        return 'Type';
      case 'uploader':
        return 'Uploader';
      case 'tag':
      case 'female':
      case 'male':
        return 'Tags';
    }
    return '';
  }

  static bool isSingleTag(String prefix) {
    switch (prefix) {
      case 'language':
      case 'class':
      case 'type':
      case 'uploader':
        return true;
      case 'artist':
      case 'group':
      case 'character':
      case 'tag':
      case 'female':
      case 'male':
      case 'series':
      default:
        return false;
    }
  }
}
