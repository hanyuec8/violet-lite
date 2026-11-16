// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:violet/component/hangul_auto_restorer.dart';
import 'package:violet/database/incremental_index_sync.dart';
import 'package:violet/settings/settings.dart';

/// Translate search query to sql query
String translate2query(String query, {bool filter = true}) {
  query = HangulAutoRestorer.normalizeQuery(query.trim());
  final tokens = _splitTokens(
    query,
  ).map((x) => x.trim()).where((x) => x != '').toList();

  final filterExistsOnHitomi = !Settings.searchPure.value && filter;

  if (tokens.isEmpty) {
    return 'SELECT * FROM HitomiColumnModel ${filterExistsOnHitomi ? "WHERE ExistOnHitomi=1" : ""}';
  }

  // 순수 숫자(단일 품번) 단독 검색인 경우 고속 직결 (부정형 -12345 제외)
  if (tokens.length == 1 && !tokens[0].startsWith('-')) {
    final nn = int.tryParse(tokens[0]);
    if (nn != null && nn > 0) {
      return 'SELECT * FROM HitomiColumnModel WHERE Id=$nn';
    }
  }

  final where = _QueryTranslator(tokens).parseExpression().trim();

  if (where.isEmpty) {
    return 'SELECT * FROM HitomiColumnModel ${filterExistsOnHitomi ? "WHERE ExistOnHitomi=1" : ""}';
  }

  return 'SELECT * FROM HitomiColumnModel WHERE ($where) ${filterExistsOnHitomi ? " AND ExistOnHitomi=1" : ""}';
}

List<String> _splitTokens(String tokens) {
  final result = <String>[];
  final builder = StringBuffer();
  for (int i = 0; i < tokens.length; i++) {
    if (tokens[i] == ' ') {
      result.add(builder.toString());
      builder.clear();
      continue;
    } else if (tokens[i] == '(' || tokens[i] == ')') {
      result.add(builder.toString());
      builder.clear();
      result.add(tokens[i]);
      continue;
    }

    builder.write(tokens[i]);
  }

  result.add(builder.toString());
  return result;
}

class _QueryTranslator {
  final List<String> tokens;
  int index = 0;

  _QueryTranslator(this.tokens);

  String parseExpression() {
    if (index >= tokens.length) return '';

    String token = nextToken();
    var where = '';
    bool negative = false;

    if (token.startsWith('-')) {
      negative = true;
      if (token == '-') {
        token = nextToken();
      } else {
        token = token.substring(1);
      }
    }

    if (token.startsWith('page') &&
        (token.contains('>') || token.contains('=') || token.contains('<'))) {
      where += parsePageExpression(token, negative);
    } else if (token.startsWith('id') &&
        (token.contains('>') ||
            token.contains('=') ||
            token.contains('<') ||
            token.contains('!='))) {
      where += parseIdExpression(token, negative);
    } else if ((token.startsWith('date') || token.startsWith('published')) &&
        (token.contains('>') || token.contains('=') || token.contains('<'))) {
      where += parseDateExpression(token, negative);
    } else if (token.contains(':')) {
      where += parseTag(token, negative);
    } else if (negative && int.tryParse(token) != null) {
      where += 'Id != $token';
    } else if (token == 'random') {
      // random 단독 토큰은 WHERE 절에서 무시 (ORDER BY에서 처리)
      where += '';
    } else if (token == '(') {
      final inner = parseExpression();
      if (hasMoreTokens()) nextToken();
      where += negative ? 'NOT ($inner)' : '($inner)';
      if (hasMoreTokens() && lookAhead() != ')') {
        final logic = parseLogicalExpression();
        if (logic.isNotEmpty) where += logic;
      }
      return where;
    } else if (token == ')') {
      return token;
    } else {
      where += parseTitle(token, negative);
    }

    if (where.trim().isEmpty) {
      if (hasMoreTokens() && lookAhead() != ')') {
        return parseExpression();
      }
      return '';
    }

    if (hasMoreTokens() && lookAhead() != ')') {
      final logic = parseLogicalExpression();
      if (logic.isNotEmpty) where += logic;
    }

    return where;
  }

  String parseTag(String token, bool negative) {
    var ss = token.split(':');
    final tagType = ss[0].toLowerCase();

    // random:seed 무시 (ORDER BY에서 처리)
    if (tagType == 'random') return '';

    // 번호 구간 (id:1000~2000, id:1000..2000, id:1000-2000, id:1000)
    if (tagType == 'id') {
      final rangeMatch = RegExp(r'^id:(\d+)(?:~|\.\.|\-)(\d+)$', caseSensitive: false).firstMatch(token);
      if (rangeMatch != null) {
        final start = rangeMatch.group(1)!;
        final end = rangeMatch.group(2)!;
        return negative ? '(Id < $start OR Id > $end)' : '(Id >= $start AND Id <= $end)';
      }
      final singleMatch = RegExp(r'^id:(\d+)$', caseSensitive: false).firstMatch(token);
      if (singleMatch != null) {
        final idVal = singleMatch.group(1)!;
        return negative ? 'Id != $idVal' : 'Id = $idVal';
      }
      return '';
    }

    // 날짜 구간 (date:2023-01-01~2024-01-01, date:2023~2024, published:...)
    if (tagType == 'date' || tagType == 'published') {
      final dateRangeMatch = RegExp(r'^(?:date|published):(\d{4}(?:-\d{2}-\d{2})?)(?:~|\.\.)(\d{4}(?:-\d{2}-\d{2})?)$', caseSensitive: false).firstMatch(token);
      if (dateRangeMatch != null) {
        var start = dateRangeMatch.group(1)!;
        var end = dateRangeMatch.group(2)!;
        if (start.length == 4) start = '$start-01-01';
        if (end.length == 4) end = '$end-12-31';
        return negative
            ? "(Published < '$start' OR Published > '$end 23:59:59')"
            : "(Published >= '$start' AND Published <= '$end 23:59:59')";
      }
      final singleDateMatch = RegExp(r'^(?:date|published):(\d{4}(?:-\d{2}-\d{2})?)$', caseSensitive: false).firstMatch(token);
      if (singleDateMatch != null) {
        final d = singleDateMatch.group(1)!;
        if (d.length == 4) {
          return negative
              ? "(Published < '$d-01-01' OR Published > '$d-12-31 23:59:59')"
              : "(Published >= '$d-01-01' AND Published <= '$d-12-31 23:59:59')";
        } else {
          return negative
              ? "(Published NOT LIKE '$d%')"
              : "(Published LIKE '$d%')";
        }
      }
      return '';
    }

    var column = findColumnByTag(tagType);
    if (column == '') return '';

    var name = '';
    switch (tagType) {
      case 'male':
      case 'female':
        if (IncrementalIndexSyncService.isFtsTagsReady) {
          final ftsToken = token.replaceAll(' ', '_').replaceAll('"', '""');
          final sub = "Id IN (SELECT rowid FROM FtsTags WHERE Tags MATCH '\"$ftsToken\"')";
          return negative ? 'NOT ($sub)' : sub;
        }
        name = '|${token.replaceAll('_', ' ')}|';
        break;

      case 'tag':
      case 'series':
      case 'character':
        if (IncrementalIndexSyncService.isFtsTagsReady) {
          final ftsCol = tagType == 'tag'
              ? 'Tags'
              : tagType == 'series'
                  ? 'Series'
                  : 'Characters';
          final ftsToken = ss[1].replaceAll(' ', '_').replaceAll('"', '""');
          final sub =
              "Id IN (SELECT rowid FROM FtsTags WHERE $ftsCol MATCH '\"$ftsToken\"')";
          return negative ? 'NOT ($sub)' : sub;
        }
        name = '|${ss[1].replaceAll('_', ' ')}|';
        break;

      case 'artist':
      case 'group':
        // 단어 단위 경계(Word Boundary) 매칭: 성/이름 단독 검색(tadataka)은 유지하면서
        // in, yu, rin 등 짧은 철자가 단어 중간에 낀 엉뚱한 작가들의 오매칭을 원천 차단
        name = ss[1].replaceAll('_', ' ');
        final sanitizedArtist = name.replaceAll("'", "''");
        final compare =
            "($column LIKE '%|$sanitizedArtist|%' OR $column LIKE '%|$sanitizedArtist %' OR $column LIKE '% $sanitizedArtist|%' OR $column LIKE '% $sanitizedArtist %')";
        return negative ? 'NOT $compare' : compare;

      case 'uploader':
        final sanitizedUp = ss[1].replaceAll("'", "''");
        final upCompare = "Uploader = '$sanitizedUp' COLLATE NOCASE";
        return negative ? '($upCompare) IS NOT 1' : upCompare;

      case 'lang':
      case 'language':
      case 'type':
        final exactVal =
            ss[1].replaceAll('_', ' ').toLowerCase().replaceAll("'", "''");
        final exactCmp = "$column = '$exactVal'";
        return negative ? '($exactCmp) IS NOT 1' : exactCmp;

      case 'class':
        final exactClass = ss[1].replaceAll('_', ' ').replaceAll("'", "''");
        final classCmp = "$column = '$exactClass' COLLATE NOCASE";
        return negative ? '($classCmp) IS NOT 1' : classCmp;
    }

    name = name.replaceAll("'", "''");
    var compare = "$column LIKE '%$name%'";
    if (column == 'Uploader') compare += ' COLLATE NOCASE';

    return (negative ? '($compare) IS NOT 1' : compare);
  }

  String parsePageExpression(String token, bool negative) {
    final re = RegExp(r'page([\=\<\>]{1,2})(\d+)', caseSensitive: false);
    if (re.hasMatch(token)) {
      final matches = re.allMatches(token).elementAt(0);
      final op = matches.group(1)!;
      final val = matches.group(2)!;
      if (negative) {
        final negOp = op == '>=' ? '<' : op == '<=' ? '>' : op == '>' ? '<=' : op == '<' ? '>=' : '!=';
        return 'Files $negOp $val';
      }
      return 'Files $op $val';
    }
    return '';
  }

  String parseIdExpression(String token, bool negative) {
    final re = RegExp(r'id(!=|>=|<=|==|=|<|>)(\d+)', caseSensitive: false);
    if (re.hasMatch(token)) {
      final matches = re.allMatches(token).elementAt(0);
      final op = matches.group(1)!;
      final val = matches.group(2)!;
      if (op == '!=') {
        return negative ? 'Id = $val' : 'Id != $val';
      }
      if (negative) {
        final negOp = op == '>=' ? '<' : op == '<=' ? '>' : op == '>' ? '<=' : op == '<' ? '>=' : '!=';
        return 'Id $negOp $val';
      }
      return 'Id ${op == '==' ? '=' : op} $val';
    }
    return '';
  }

  String parseDateExpression(String token, bool negative) {
    final re = RegExp(r'(?:date|published)([\=\<\>]{1,2})(\d{4}(?:-\d{2}-\d{2})?)', caseSensitive: false);
    if (re.hasMatch(token)) {
      final matches = re.allMatches(token).elementAt(0);
      final op = matches.group(1)!;
      var val = matches.group(2)!;
      if (val.length == 4) {
        if (op.contains('>')) {
          val = '$val-01-01';
        } else if (op.contains('<')) {
          val = '$val-12-31 23:59:59';
        } else {
          return negative
              ? "(Published < '$val-01-01' OR Published > '$val-12-31 23:59:59')"
              : "(Published >= '$val-01-01' AND Published <= '$val-12-31 23:59:59')";
        }
      } else {
        if (op.contains('<') && !val.contains(':')) {
          val = '$val 23:59:59';
        }
      }
      if (negative) {
        final negOp = op == '>=' ? '<' : op == '<=' ? '>' : op == '>' ? '<=' : op == '<' ? '>=' : '!=';
        return "Published $negOp '$val'";
      }
      return "Published $op '$val'";
    }
    return '';
  }

  String parseParentheses(String token, bool negative) {
    return negative ? 'NOT $token' : token;
  }

  String parseTitle(String token, bool negative) {
    final sanitized = token.replaceAll("'", "''");
    final restoredKor = Settings.enableHangulTypoRestore.value
        ? HangulAutoRestorer.tryRestoreKoreanWord(token)
        : null;

    if (restoredKor != null && restoredKor != token) {
      final sanitizedKor = restoredKor.replaceAll("'", "''");
      final expr =
          "(Title LIKE '%$sanitized%' OR Title LIKE '%$sanitizedKor%')";
      return negative ? 'NOT $expr' : expr;
    }

    if (IncrementalIndexSyncService.isFtsTitleReady &&
        token.runes.length >= 3 &&
        !token.contains('"')) {
      final ftsSub =
          "Id IN (SELECT rowid FROM FtsTitle WHERE Title MATCH '\"$sanitized\"')";
      return negative ? 'NOT ($ftsSub)' : ftsSub;
    }

    return negative
        ? "Title NOT LIKE '%$sanitized%'"
        : "Title LIKE '%$sanitized%'";
  }

  String parseLogicalExpression() {
    String next = lookAhead();
    late String op;
    if (next.toLowerCase() == 'or') {
      nextToken();
      op = 'OR';
    } else {
      op = 'AND';
    }
    final nextExpr = parseExpression().trim();
    if (nextExpr.isEmpty) return '';
    return ' $op $nextExpr';
  }

  String nextToken() => tokens[index++];
  String lookAhead() => index < tokens.length ? tokens[index] : '';
  bool hasMoreTokens() => index < tokens.length;

  static String findColumnByTag(String tag) {
    switch (tag) {
      case 'male':
      case 'female':
      case 'tag':
        return 'Tags';

      case 'lang':
      case 'language':
        return 'Language';

      case 'series':
        return 'Series';

      case 'artist':
        return 'Artists';

      case 'group':
        return 'Groups';

      case 'uploader':
        return 'Uploader';

      case 'character':
        return 'Characters';

      case 'type':
        return 'Type';

      case 'class':
        return 'Class';
    }

    return tag;
  }
}
