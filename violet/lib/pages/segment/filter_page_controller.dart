// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:violet/component/hitomi/population.dart';
import 'package:violet/component/local_article_filter.dart';
import 'package:violet/database/query.dart';
import 'package:violet/settings/settings.dart';

class FilterController {
  var isOr = false;
  var isSearch = false;
  var isPopulationSort = false;
  String heroKey;

  var tagStates = <String, bool>{};
  var groupStates = <String, bool>{};

  int? minPages;
  int? maxPages;
  String localQuery = '';

  bool get hasActivePageFilter =>
      minPages != null ||
      maxPages != null ||
      RegExp(r'(?:^|\s)-?page(?:>=|<=|==|>|<|=|:)', caseSensitive: false)
          .hasMatch(localQuery);

  bool get hasAnyActiveFilter =>
      tagStates.values.any((v) => v) ||
      minPages != null ||
      maxPages != null ||
      localQuery.trim().isNotEmpty;

  void resetPageFilter() {
    minPages = null;
    maxPages = null;
  }

  FilterController({this.heroKey = 'searchtype'});

  List<QueryResult> applyFilter(List<QueryResult> queryResult) {
    var result = <QueryResult>[];

    final activeFilters = tagStates.entries.where((e) => e.value).toList();
    if (activeFilters.isEmpty) {
      result = List<QueryResult>.from(queryResult);
    } else {
      for (var element in queryResult) {
        var succ = !isOr;
        for (final entry in activeFilters) {
          if (succ == isOr) break;

          final split = entry.key.split('|');
          final group = split[0];
          final targetName = split[1].trim().toLowerCase().replaceAll(' ', '_');
          final dbColumn = prefix2Tag(group);

          final rawCol = element.result[dbColumn];
          if (rawCol == null) {
            if (!isOr) succ = false;
            continue;
          }

          final colStr = rawCol.toString().trim().toLowerCase();
          bool matched = false;

          if (isSingleTag(group)) {
            final normalizedCol = colStr.replaceAll(' ', '_');
            matched = (normalizedCol == targetName);
          } else {
            final tokens = colStr
                .split('|')
                .map((t) => t.trim().replaceAll(' ', '_'))
                .where((t) => t.isNotEmpty)
                .toSet();

            String fullTag = targetName;
            if (group == 'female' || group == 'male') {
              fullTag = '$group:$targetName';
            }

            matched = tokens.contains(fullTag) || tokens.contains(targetName);
          }

          if (matched == isOr) {
            succ = isOr;
          }
        }
        if (succ) result.add(element);
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
