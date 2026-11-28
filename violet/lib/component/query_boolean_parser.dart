// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:violet/database/query.dart';
import 'package:violet/settings/settings.dart';

/// 검색 쿼리의 불리언 AST 노드
sealed class QueryBoolNode {
  const QueryBoolNode();
}

final class QueryTermNode extends QueryBoolNode {
  final String rawToken;
  final String coreToken;
  final bool negative;

  const QueryTermNode({
    required this.rawToken,
    required this.coreToken,
    this.negative = false,
  });

  String get signedToken => negative ? '-$coreToken' : coreToken;
}

final class QueryAndNode extends QueryBoolNode {
  final List<QueryBoolNode> children;

  const QueryAndNode(this.children);
}

final class QueryOrNode extends QueryBoolNode {
  final List<QueryBoolNode> children;

  const QueryOrNode(this.children);
}

final class QueryNotNode extends QueryBoolNode {
  final QueryBoolNode child;

  const QueryNotNode(this.child);
}

/// `AND`(공백), `OR`(`or`), 괄호(`(...)`), 부정(`-`)을 지원하는 불리언 쿼리 파서
class QueryBooleanParser {
  static final RegExp _directiveRegex = RegExp(
    r'^(?:random(?::.*)?|order:[a-zA-Z0-9_-]+)$',
    caseSensitive: false,
  );

  static bool isDirectiveToken(String raw) {
    final t = raw.replaceAll(RegExp(r'[\(\)]'), '').trim();
    return t.isNotEmpty && _directiveRegex.hasMatch(t);
  }

  static bool isLanguageToken(String raw) {
    final t = raw.replaceAll(RegExp(r'[\(\)]'), '').trim().toLowerCase();
    if (t.isEmpty) return false;
    if (t.startsWith('lang:') || t.startsWith('language:')) return true;
    if (t == 'korean' ||
        t == 'ko' ||
        t == 'korea' ||
        t == '한국어' ||
        t == 'japanese' ||
        t == 'ja' ||
        t == 'japan' ||
        t == '일본어' ||
        t == 'english' ||
        t == 'en' ||
        t == '영어' ||
        t == 'chinese' ||
        t == 'zh' ||
        t == '중국어' ||
        t == 'tag:korean' ||
        t == 'tag:japanese' ||
        t == 'tag:english' ||
        t == 'tag:chinese') {
      return true;
    }
    return false;
  }

  static bool isFilterOrNegativeToken(String rawToken) {
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

  /// 쿼리를 공백 및 괄호 `(`, `)` 단위로 토큰화합니다.
  /// `-(a or b)` 형태는 `['-', '(', 'a', 'or', 'b', ')']`로 분리합니다.
  static List<String> tokenize(String query) {
    final result = <String>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.isNotEmpty) {
        final s = buf.toString().trim();
        if (s.isNotEmpty) result.add(s);
        buf.clear();
      }
    }

    for (var i = 0; i < query.length; i++) {
      final ch = query[i];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        flush();
      } else if (ch == '(' || ch == ')') {
        if (ch == '(' && buf.toString() == '-') {
          result.add('-');
          buf.clear();
          result.add('(');
        } else {
          flush();
          result.add(ch);
        }
      } else {
        buf.write(ch);
      }
    }
    flush();
    return result;
  }

  static bool containsOr(String query) {
    return tokenize(query).any((t) => t.toLowerCase() == 'or');
  }

  /// 쿼리 문자열을 불리언 AST로 파싱합니다.
  /// 비어 있거나 유효한 토큰이 없으면 `null`을 반환합니다.
  static QueryBoolNode? parse(String query) {
    final tokens = tokenize(query);
    if (tokens.isEmpty) return null;
    final parser = _Parser(tokens);
    return parser.parseOr();
  }

  /// AST를 E-Hentai 검색 분기용 DNF(OR of ANDs) 리스트로 전개합니다.
  /// 각 내부 리스트는 AND로 결합할 signed token 목록이며,
  /// 분기 수가 [maxBranches]를 초과하면 잘라 과도한 네트워크 요청을 방지합니다.
  static List<List<String>> expandToDnf(
    QueryBoolNode? node, {
    int maxBranches = 4,
  }) {
    if (node == null) return const [];
    final expanded = _toDnf(node, maxBranches: maxBranches);
    if (expanded.length > maxBranches) {
      return expanded.sublist(0, maxBranches);
    }
    return expanded;
  }

  static List<List<String>> _toDnf(
    QueryBoolNode node, {
    required int maxBranches,
  }) {
    switch (node) {
      case QueryTermNode():
        return [
          [node.signedToken],
        ];
      case QueryOrNode():
        final result = <List<String>>[];
        for (final child in node.children) {
          result.addAll(_toDnf(child, maxBranches: maxBranches));
          if (result.length >= maxBranches) {
            return result.sublist(0, maxBranches);
          }
        }
        return result;
      case QueryAndNode():
        var current = <List<String>>[const []];
        for (final child in node.children) {
          final childDnf = _toDnf(child, maxBranches: maxBranches);
          if (childDnf.isEmpty) continue;
          final next = <List<String>>[];
          for (final left in current) {
            for (final right in childDnf) {
              next.add([...left, ...right]);
              if (next.length >= maxBranches) break;
            }
            if (next.length >= maxBranches) break;
          }
          current = next;
        }
        return current;
      case QueryNotNode():
        return _toNegatedDnf(node.child, maxBranches: maxBranches);
    }
  }

  static List<List<String>> _toNegatedDnf(
    QueryBoolNode node, {
    required int maxBranches,
  }) {
    switch (node) {
      case QueryTermNode():
        final flipped = node.negative ? node.coreToken : '-${node.coreToken}';
        return [
          [flipped],
        ];
      case QueryOrNode():
        // !(A OR B) == (!A AND !B)
        return _toDnf(
          QueryAndNode(node.children.map(QueryNotNode.new).toList()),
          maxBranches: maxBranches,
        );
      case QueryAndNode():
        // !(A AND B) == (!A OR !B)
        return _toDnf(
          QueryOrNode(node.children.map(QueryNotNode.new).toList()),
          maxBranches: maxBranches,
        );
      case QueryNotNode():
        return _toDnf(node.child, maxBranches: maxBranches);
    }
  }

  /// AST를 [QueryResult]에 대해 평가하여 조건 만족 여부를 반환합니다.
  static bool matchesQueryNode(QueryResult item, QueryBoolNode node) {
    final ctx = _ItemMatchContext.from(item);
    return _evalNode(ctx, node);
  }

  static bool _evalNode(_ItemMatchContext ctx, QueryBoolNode node) {
    switch (node) {
      case QueryAndNode():
        return node.children.every((child) => _evalNode(ctx, child));
      case QueryOrNode():
        return node.children.any((child) => _evalNode(ctx, child));
      case QueryNotNode():
        return !_evalNode(ctx, node.child);
      case QueryTermNode():
        if (isDirectiveToken(node.coreToken)) return true;
        final matched = ctx.matchesPositiveTerm(node.coreToken);
        return node.negative ? !matched : matched;
    }
  }
}

class _Parser {
  final List<String> tokens;
  int _index = 0;

  _Parser(this.tokens);

  bool get _hasMore => _index < tokens.length;
  String get _peek => tokens[_index];
  String _consume() => tokens[_index++];

  QueryBoolNode? parseOr() {
    final branches = <QueryBoolNode>[];
    final first = parseAnd();
    if (first != null) branches.add(first);

    while (_hasMore && _peek.toLowerCase() == 'or') {
      _consume();
      final next = parseAnd();
      if (next != null) branches.add(next);
    }

    if (branches.isEmpty) return null;
    if (branches.length == 1) return branches.first;
    return QueryOrNode(branches);
  }

  QueryBoolNode? parseAnd() {
    final factors = <QueryBoolNode>[];

    while (_hasMore) {
      final tok = _peek;
      if (tok == ')' || tok.toLowerCase() == 'or') break;
      final node = parsePrimary();
      if (node != null) factors.add(node);
    }

    if (factors.isEmpty) return null;
    if (factors.length == 1) return factors.first;
    return QueryAndNode(factors);
  }

  QueryBoolNode? parsePrimary() {
    if (!_hasMore) return null;
    var tok = _consume();

    if (tok == ')') return null;

    if (tok == '-') {
      if (!_hasMore) return null;
      if (_peek == '(') {
        _consume();
        final inner = parseOr();
        if (_hasMore && _peek == ')') _consume();
        return inner == null ? null : QueryNotNode(inner);
      }
      final next = _consume();
      if (next == ')') return null;
      return QueryTermNode(
        rawToken: '-$next',
        coreToken: next,
        negative: true,
      );
    }

    if (tok == '(') {
      final inner = parseOr();
      if (_hasMore && _peek == ')') _consume();
      return inner;
    }

    if (tok.startsWith('-') && tok.length > 1) {
      return QueryTermNode(
        rawToken: tok,
        coreToken: tok.substring(1),
        negative: true,
      );
    }

    return QueryTermNode(
      rawToken: tok,
      coreToken: tok,
      negative: false,
    );
  }
}

class _ItemMatchContext {
  final QueryResult item;
  final int? itemId;
  final List<String> tagList;
  final List<String> artistList;
  final List<String> groupList;
  final List<String> seriesList;
  final List<String> characterList;
  final String title;
  final String languageNormalized;

  _ItemMatchContext({
    required this.item,
    required this.itemId,
    required this.tagList,
    required this.artistList,
    required this.groupList,
    required this.seriesList,
    required this.characterList,
    required this.title,
    required this.languageNormalized,
  });

  factory _ItemMatchContext.from(QueryResult item) {
    List<String> splitPipe(dynamic raw) {
      final str = raw?.toString() ?? '';
      return str
          .split('|')
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty && e != 'n/a')
          .toList();
    }

    final rawId = item.result['Id'];
    final itemId = rawId is num
        ? rawId.toInt()
        : int.tryParse(rawId?.toString() ?? '');

    return _ItemMatchContext(
      item: item,
      itemId: itemId,
      tagList: splitPipe(item.tags()),
      artistList: splitPipe(item.artists()),
      groupList: splitPipe(item.groups()),
      seriesList: splitPipe(item.series()),
      characterList: splitPipe(item.characters()),
      title: (item.title() ?? '').toString().toLowerCase(),
      languageNormalized: _normalizeLang(item.language()?.toString() ?? ''),
    );
  }

  static String _normalizeLang(String raw) {
    final l = raw.toLowerCase().trim();
    if (l.isEmpty || l == 'n/a') return l;
    if (l == 'ko' || l == 'korea' || l.contains('korean') || l.contains('한국어')) {
      return 'korean';
    }
    if (l == 'ja' ||
        l == 'japan' ||
        l.contains('japanese') ||
        l.contains('일본어') ||
        l.contains('日本語')) {
      return 'japanese';
    }
    if (l == 'en' || l.contains('english') || l.contains('영어')) {
      return 'english';
    }
    if (l == 'zh' ||
        l.contains('chinese') ||
        l.contains('중국어') ||
        l.contains('中文')) {
      return 'chinese';
    }
    if (l.contains('spanish') || l.contains('español') || l.contains('스페인어')) {
      return 'spanish';
    }
    return l;
  }

  bool matchesPositiveTerm(String coreToken) {
    final tok = coreToken.trim();
    if (tok.isEmpty) return true;
    final lowerTok = tok.toLowerCase();

    if (lowerTok.startsWith('id:') ||
        RegExp(r'^id(?:!=|>=|<=|==|>|<|=)\d+$').hasMatch(lowerTok)) {
      return itemId != null && Settings.matchesIdRule(itemId!, lowerTok);
    }

    if (int.tryParse(lowerTok) != null) {
      final targetId = int.parse(lowerTok);
      return itemId != null && itemId == targetId;
    }

    if (RegExp(r'^page(?:>=|<=|==|>|<|=|:)').hasMatch(lowerTok)) {
      final rawFiles = item.files();
      final pages = rawFiles is num
          ? rawFiles.toInt()
          : int.tryParse(rawFiles?.toString() ?? '');
      if (pages == null) return true;
      final cmp = RegExp(r'^page(>=|<=|==|>|<|=)(\d+)$').firstMatch(lowerTok);
      final rng = RegExp(r'^page:(\d*)~(\d*)$').firstMatch(lowerTok);
      final exact = RegExp(r'^page:(\d+)$').firstMatch(lowerTok);
      if (cmp != null) {
        final op = cmp.group(1)!;
        final v = int.parse(cmp.group(2)!);
        return switch (op) {
          '>' => pages > v,
          '>=' => pages >= v,
          '<' => pages < v,
          '<=' => pages <= v,
          '=' || '==' => pages == v,
          _ => true,
        };
      }
      if (rng != null) {
        final minP = int.tryParse(rng.group(1) ?? '');
        final maxP = int.tryParse(rng.group(2) ?? '');
        if (minP != null && pages < minP) return false;
        if (maxP != null && pages > maxP) return false;
        return true;
      }
      if (exact != null) {
        return pages == int.parse(exact.group(1)!);
      }
      return true;
    }

    if (RegExp(r'^(?:date|published)(?:>=|<=|==|>|<|=|:)').hasMatch(lowerTok)) {
      return true;
    }

    final colonIdx = tok.indexOf(':');
    if (colonIdx != -1) {
      final prefix = tok.substring(0, colonIdx).trim().toLowerCase();
      final val = tok.substring(colonIdx + 1).trim().toLowerCase();
      final valSpaced = val.replaceAll('_', ' ');

      switch (prefix) {
        case 'female':
          return tagList.any(
            (t) => t == 'female:$val' || t == 'female:$valSpaced',
          );
        case 'male':
          return tagList.any(
            (t) => t == 'male:$val' || t == 'male:$valSpaced',
          );
        case 'tag':
          return tagList.any(
            (t) =>
                t == val ||
                t == valSpaced ||
                t == 'female:$val' ||
                t == 'female:$valSpaced' ||
                t == 'male:$val' ||
                t == 'male:$valSpaced',
          );
        case 'artist':
          return artistList.any((a) => a == val || a == valSpaced);
        case 'group':
          return groupList.any((g) => g == val || g == valSpaced);
        case 'series':
          return seriesList.any((s) => s == val || s == valSpaced);
        case 'character':
          return characterList.any((c) => c == val || c == valSpaced);
        case 'uploader':
          final upl = (item.uploader() ?? '').toString().toLowerCase().trim();
          return upl == val || upl == valSpaced;
        case 'type':
          final tp = (item.type() ?? '').toString().toLowerCase().trim();
          return tp == val || tp == valSpaced;
        case 'class':
          final cls = (item.classname() ?? '').toString().toLowerCase().trim();
          return cls == val || cls == valSpaced;
        case 'lang':
        case 'language':
          final targetLang = _normalizeLang(val);
          if (targetLang == 'all') return true;
          return languageNormalized == targetLang;
        default:
          return tagList.any(
            (t) => t == '$prefix:$val' || t == '$prefix:$valSpaced',
          );
      }
    }

    final val = lowerTok;
    final valSpaced = val.replaceAll('_', ' ');
    return tagList.any(
          (t) =>
              t == val ||
              t == valSpaced ||
              t == 'female:$val' ||
              t == 'female:$valSpaced' ||
              t == 'male:$val' ||
              t == 'male:$valSpaced' ||
              t.contains(val) ||
              t.contains(valSpaced),
        ) ||
        title.contains(val) ||
        title.contains(valSpaced) ||
        artistList.any((a) => a.contains(val) || a.contains(valSpaced)) ||
        seriesList.any((s) => s.contains(val) || s.contains(valSpaced));
  }
}
