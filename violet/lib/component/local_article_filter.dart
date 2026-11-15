// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:violet/component/hangul_auto_restorer.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/database/query.dart';

enum PageCompareOp { gt, gte, lt, lte, eq }

class PageFilterCondition {
  final PageCompareOp operator;
  final int count;

  const PageFilterCondition({
    required this.operator,
    required this.count,
  });

  bool matches(int pages) {
    switch (operator) {
      case PageCompareOp.gt:
        return pages > count;
      case PageCompareOp.gte:
        return pages >= count;
      case PageCompareOp.lt:
        return pages < count;
      case PageCompareOp.lte:
        return pages <= count;
      case PageCompareOp.eq:
        return pages == count;
    }
  }
}

class LocalFilterToken {
  final PageFilterCondition? pageCondition;
  final int? minPageRange;
  final int? maxPageRange;
  final String? field;
  final String value;
  final String? restoredKoreanValue;
  final bool negative;

  const LocalFilterToken({
    this.pageCondition,
    this.minPageRange,
    this.maxPageRange,
    this.field,
    required this.value,
    this.restoredKoreanValue,
    this.negative = false,
  });
}

class LocalArticleFilter {
  static const Set<String> _validFields = {
    'artist', 'tag', 'series', 'character', 'group', 'male',
    'female', 'lang', 'language', 'type', 'class', 'uploader',
  };

  static int? extractPageCount(QueryResult article) {
    final raw = article.files();
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString().trim());
  }

  static List<String> _splitPipe(dynamic raw) {
    if (raw == null) return const [];
    final s = raw.toString();
    if (s.isEmpty) return const [];
    return s
        .split('|')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static String _normalizeVal(String v) => v.toLowerCase().replaceAll('_', ' ');

  static PageCompareOp? _parseOp(String op) {
    switch (op) {
      case '>':
        return PageCompareOp.gt;
      case '>=':
        return PageCompareOp.gte;
      case '<':
        return PageCompareOp.lt;
      case '<=':
        return PageCompareOp.lte;
      case '=':
      case '==':
        return PageCompareOp.eq;
      default:
        return null;
    }
  }

  static List<LocalFilterToken> parseQuery(
    String query, {
    bool restoreTypos = true,
  }) {
    final normalizedQuery =
        restoreTypos ? HangulAutoRestorer.normalizeQuery(query) : query;
    final rawTokens = normalizedQuery
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    final parsed = <LocalFilterToken>[];
    for (final raw in rawTokens) {
      final negative = raw.startsWith('-') && raw.length > 1;
      final core = negative ? raw.substring(1) : raw;
      final lowerCore = core.toLowerCase();

      final pageCmp =
          RegExp(r'^page(>=|<=|==|>|<|=)(\d+)$').firstMatch(lowerCore);
      if (pageCmp != null) {
        final op = _parseOp(pageCmp.group(1)!);
        final numVal = int.tryParse(pageCmp.group(2)!);
        if (op != null && numVal != null) {
          parsed.add(LocalFilterToken(
            pageCondition: PageFilterCondition(operator: op, count: numVal),
            value: lowerCore,
            negative: negative,
          ));
          continue;
        }
      }

      final pageRange = RegExp(r'^page:(\d*)~(\d*)$').firstMatch(lowerCore);
      if (pageRange != null) {
        final minP = int.tryParse(pageRange.group(1) ?? '');
        final maxP = int.tryParse(pageRange.group(2) ?? '');
        if (minP != null || maxP != null) {
          parsed.add(LocalFilterToken(
            minPageRange: minP,
            maxPageRange: maxP,
            value: lowerCore,
            negative: negative,
          ));
          continue;
        }
      }

      final pageExactColon = RegExp(r'^page:(\d+)$').firstMatch(lowerCore);
      if (pageExactColon != null) {
        final exactP = int.tryParse(pageExactColon.group(1)!);
        if (exactP != null) {
          parsed.add(LocalFilterToken(
            pageCondition:
                PageFilterCondition(operator: PageCompareOp.eq, count: exactP),
            value: lowerCore,
            negative: negative,
          ));
          continue;
        }
      }

      final colonIdx = core.indexOf(':');
      if (colonIdx > 0) {
        final field = core.substring(0, colonIdx).toLowerCase();
        final rawVal = core.substring(colonIdx + 1);
        if (_validFields.contains(field) && rawVal.isNotEmpty) {
          final restoredKor = restoreTypos
              ? HangulAutoRestorer.tryRestoreKoreanWord(rawVal)
              : null;
          parsed.add(LocalFilterToken(
            field: field == 'language' ? 'lang' : field,
            value: rawVal.toLowerCase(),
            restoredKoreanValue: restoredKor,
            negative: negative,
          ));
          continue;
        }
      }

      parsed.add(LocalFilterToken(
        value: core.toLowerCase(),
        restoredKoreanValue:
            restoreTypos ? HangulAutoRestorer.tryRestoreKoreanWord(core) : null,
        negative: negative,
      ));
    }
    return parsed;
  }

  static bool matchesToken(QueryResult article, LocalFilterToken token) {
    if (token.pageCondition != null ||
        token.minPageRange != null ||
        token.maxPageRange != null) {
      final pages = extractPageCount(article);
      if (pages == null) return false;

      bool ok = true;
      if (token.pageCondition != null) {
        ok = token.pageCondition!.matches(pages);
      } else {
        if (token.minPageRange != null && pages < token.minPageRange!) {
          ok = false;
        }
        if (token.maxPageRange != null && pages > token.maxPageRange!) {
          ok = false;
        }
      }
      return token.negative ? !ok : ok;
    }

    final rawMatches = _matchesFieldOrText(article, token.field, token.value) ||
        (token.restoredKoreanValue != null &&
            _matchesFieldOrText(
              article,
              token.field,
              token.restoredKoreanValue!,
            ));
    return token.negative ? !rawMatches : rawMatches;
  }

  static bool _matchesFieldOrText(
    QueryResult article,
    String? field,
    String targetVal,
  ) {
    final norm = _normalizeVal(targetVal);

    if (field != null) {
      switch (field) {
        case 'artist':
          return _splitPipe(article.artists())
              .any((a) => a.toLowerCase().contains(norm));
        case 'series':
          return _splitPipe(article.series()).any((s) =>
              s.toLowerCase().contains(norm) ||
              TagTranslate.of('series', s).toLowerCase().contains(norm));
        case 'character':
          return _splitPipe(article.characters()).any((c) =>
              c.toLowerCase().contains(norm) ||
              TagTranslate.of('character', c).toLowerCase().contains(norm));
        case 'group':
          return _splitPipe(article.groups())
              .any((g) => g.toLowerCase().contains(norm));
        case 'tag':
        case 'male':
        case 'female':
          final rawTags = _splitPipe(article.tags());
          return rawTags.any((t) {
            final lower = t.toLowerCase();
            if (field == 'male' && !lower.startsWith('male:')) return false;
            if (field == 'female' && !lower.startsWith('female:')) return false;
            if (lower.contains(norm)) return true;
            final parts = lower.split(':');
            final cls = parts.length == 2 ? parts[0] : 'tag';
            final name = parts.length == 2 ? parts[1] : lower;
            return TagTranslate.of(cls, name).toLowerCase().contains(norm);
          });
        case 'lang':
          return (article.language()?.toString().toLowerCase() ?? '')
              .contains(norm);
        case 'type':
          return (article.type()?.toString().toLowerCase() ?? '').contains(norm);
        case 'class':
          return (article.classname()?.toString().toLowerCase() ?? '')
              .contains(norm);
        case 'uploader':
          return (article.uploader()?.toString().toLowerCase() ?? '')
              .contains(norm);
      }
    }

    final title = (article.title()?.toString().toLowerCase() ?? '');
    if (title.contains(norm)) return true;
    if (article.id().toString() == norm) return true;
    if (_splitPipe(article.artists()).any((a) => a.toLowerCase().contains(norm))) {
      return true;
    }
    if (_splitPipe(article.groups()).any((g) => g.toLowerCase().contains(norm))) {
      return true;
    }
    if (_splitPipe(article.series()).any((s) =>
        s.toLowerCase().contains(norm) ||
        TagTranslate.of('series', s).toLowerCase().contains(norm))) {
      return true;
    }
    if (_splitPipe(article.characters()).any((c) =>
        c.toLowerCase().contains(norm) ||
        TagTranslate.of('character', c).toLowerCase().contains(norm))) {
      return true;
    }
    return _splitPipe(article.tags()).any((t) {
      final lower = t.toLowerCase();
      if (lower.contains(norm)) return true;
      final parts = lower.split(':');
      final cls = parts.length == 2 ? parts[0] : 'tag';
      final name = parts.length == 2 ? parts[1] : lower;
      return TagTranslate.of(cls, name).toLowerCase().contains(norm);
    });
  }

  static List<QueryResult> filter(
    List<QueryResult> articles,
    String query, {
    int? minPages,
    int? maxPages,
    bool restoreTypos = true,
  }) {
    final tokens = query.trim().isEmpty
        ? const <LocalFilterToken>[]
        : parseQuery(query, restoreTypos: restoreTypos);

    if (tokens.isEmpty && minPages == null && maxPages == null) {
      return articles;
    }

    return articles.where((article) {
      if (minPages != null || maxPages != null) {
        final pages = extractPageCount(article);
        if (pages == null) return false;
        if (minPages != null && pages < minPages) return false;
        if (maxPages != null && pages > maxPages) return false;
      }
      return tokens.every((t) => matchesToken(article, t));
    }).toList();
  }
}