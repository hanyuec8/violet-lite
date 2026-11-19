// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:violet/component/hangul_auto_restorer.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/component/hitomi/displayed_tag.dart';
import 'package:violet/component/hitomi/hitomi.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/hitomi/message_corpus_manager.dart';
import 'package:violet/component/index.dart';
import 'package:violet/component/local_article_filter.dart';
import 'package:violet/database/query.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/common/utils.dart';
import 'package:violet/script/script_manager.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/message_search.dart' as rust_msg;
import 'package:violet/style/palette.dart';

enum DialogueViewMode { detail, grid }

/// 메인 검색창 전환 및 북마크 범위 검색 공용 모바일 경량 Rust 한국어 대사 검색 화면
class MessageSearchView extends StatefulWidget {
  final List<int>? scopedArticleIds;
  final String? scopeLabel;
  final VoidCallback? onClose;

  const MessageSearchView({
    super.key,
    this.scopedArticleIds,
    this.scopeLabel,
    this.onClose,
  });

  @override
  State<MessageSearchView> createState() => _MessageSearchViewState();
}

class _MessageSearchViewState extends State<MessageSearchView> {
  final _dialogueController = TextEditingController();
  final _conditionController = TextEditingController();
  final _dialogueFocusNode = FocusNode();
  final _conditionFocusNode = FocusNode();
  int _suppressInputFocusCount = 0;

  DialogueSearchMode _mode = DialogueSearchMode.contains;
  DialogueSortMode _sortMode = DialogueSortMode.relevance;
  late DialogueViewMode _viewMode;
  bool _searching = false;
  rust_msg.MobileSearchProgress? _progress;
  Timer? _pollTimer;

  static const int _pageStep = 500;
  static const int _maxTake = 10000;
  int _take = _pageStep;
  int _totalMatched = 0;

  List<rust_msg.MobileMessageHit> _hits = const [];
  final Map<int, QueryResult> _articleCache = <int, QueryResult>{};
  final Map<int, Future<ImageList>> _imageListFutures = <int, Future<ImageList>>{};
  final Map<int, Future<Map<String, String>>> _headerFutures =
      <int, Future<Map<String, String>>>{};
  String? _statusMessage;

  List<(DisplayedTag, int)> _conditionSuggestions = const [];
  Timer? _conditionDebounce;
  int _conditionTokenStart = 0;
  int _conditionTokenEnd = 0;
  String _conditionActiveToken = '';
  bool _conditionHasNegative = false;
  bool _showConditionSuggestions = false;
  int _conditionReqId = 0;

  Future<ImageList> _getImageListCached(int articleId) {
    return _imageListFutures.putIfAbsent(
      articleId,
      () => HitomiManager.getImageList('$articleId'),
    );
  }

  Future<Map<String, String>> _getHeaderCached(int articleId) {
    return _headerFutures.putIfAbsent(
      articleId,
      () => ScriptManager.runHitomiGetHeaderContent('$articleId'),
    );
  }

  String _formatCount(int n) {
    final s = n.toString();
    return s.replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  void _unfocusInputs() {
    _dialogueFocusNode.unfocus();
    _conditionFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<T> _runWithSuppressedInputFocus<T>(Future<T> Function() action) async {
    _unfocusInputs();
    if (mounted) {
      setState(() {
        _suppressInputFocusCount++;
      });
    } else {
      _suppressInputFocusCount++;
    }
    _dialogueFocusNode.canRequestFocus = false;
    _conditionFocusNode.canRequestFocus = false;
    try {
      return await action();
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _suppressInputFocusCount = math.max(0, _suppressInputFocusCount - 1);
        if (!mounted) return;
        if (_suppressInputFocusCount == 0) {
          setState(() {
            _dialogueFocusNode.canRequestFocus = true;
            _conditionFocusNode.canRequestFocus = true;
          });
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _viewMode = Settings.messageSearchGridMode.value
        ? DialogueViewMode.grid
        : DialogueViewMode.detail;
    _conditionFocusNode.addListener(_onConditionFocusChanged);
  }

  static const List<(String, String)> _conditionPrefixes = [
    ('female', '여성 태그'),
    ('male', '남성 태그'),
    ('tag', '일반 태그'),
    ('artist', '작가'),
    ('group', '그룹'),
    ('series', '시리즈'),
    ('character', '캐릭터'),
    ('uploader', '업로더'),
    ('type', '종류'),
    ('page', '페이지'),
    ('id', '작품번호'),
    ('date', '날짜'),
  ];

  static bool _isTokenBoundary(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\n' || ch == '(' || ch == ')';

  void _scheduleConditionSuggestions() {
    setState(() {
      _showConditionSuggestions = true;
    });
    _conditionDebounce?.cancel();
    _conditionDebounce = Timer(
      const Duration(milliseconds: 110),
      () => unawaited(_updateConditionSuggestions()),
    );
  }

  Future<void> _updateConditionSuggestions() async {
    if (!mounted) return;
    final text = _conditionController.text;
    final sel = _conditionController.selection;
    final rawOffset = sel.baseOffset;
    final cursor =
        (rawOffset >= 0 && rawOffset <= text.length) ? rawOffset : text.length;

    var start = cursor;
    while (start > 0 && !_isTokenBoundary(text[start - 1])) {
      start--;
    }
    var end = cursor;
    while (end < text.length && !_isTokenBoundary(text[end])) {
      end++;
    }

    final rawToken = text.substring(start, end);
    final hasNegative = rawToken.startsWith('-');
    final coreToken = hasNegative ? rawToken.substring(1) : rawToken;
    final reqId = ++_conditionReqId;

    _conditionTokenStart = start;
    _conditionTokenEnd = end;
    _conditionHasNegative = hasNegative;
    _conditionActiveToken = coreToken;

    if (coreToken.trim().isEmpty) {
      if (!mounted || reqId != _conditionReqId) return;
      setState(() {
        _conditionSuggestions = _conditionPrefixes
            .map(
              (p) => (
                DisplayedTag(group: 'prefix', name: p.$1, translated: p.$2),
                0,
              ),
            )
            .toList();
      });
      return;
    }

    var effectiveToken = coreToken.trim();
    final analyzedTypo = Settings.enableHangulTypoRestore.value
        ? HangulAutoRestorer.analyzeToken(effectiveToken)
        : null;

    final result = <(DisplayedTag, int)>[];
    final seenTags = <String>{};

    void addUnique((DisplayedTag, int) item) {
      final k = item.$1.getTag();
      if (seenTags.add(k)) {
        result.add(item);
      }
    }

    if (analyzedTypo != null) {
      if (analyzedTypo.restoredExpression != null &&
          (analyzedTypo.restoredExpression!.contains('>') ||
              analyzedTypo.restoredExpression!.contains('<') ||
              analyzedTypo.restoredExpression!.contains('='))) {
        addUnique((
          DisplayedTag(
            group: analyzedTypo.normalizedPrefix ?? 'prefix',
            name: analyzedTypo.restoredExpression!.replaceFirst(
              analyzedTypo.normalizedPrefix ?? '',
              '',
            ),
            translated: '오타 복원: ${analyzedTypo.restoredExpression}',
          ),
          0,
        ));
      } else if (analyzedTypo.normalizedPrefix != null &&
          analyzedTypo.restoredExpression != null) {
        effectiveToken = analyzedTypo.restoredExpression!;
      }
    }

    final lowerEff = effectiveToken.toLowerCase();
    if (lowerEff == 'page') {
      for (final op in const ['>', '>=', '<', '<=', '=']) {
        addUnique((DisplayedTag(group: 'page', name: op), 0));
      }
    } else if (lowerEff == 'id') {
      for (final op in const ['1000000~2000000', '>=', '<=', '>', '<', '=']) {
        addUnique((DisplayedTag(group: 'id', name: op), 0));
      }
    } else if (lowerEff == 'date') {
      for (final op in const [
        '2024-01-01~2026-12-31',
        '2023~2026',
        '>=',
        '<=',
      ]) {
        addUnique((DisplayedTag(group: 'date', name: op), 0));
      }
    }

    if (!effectiveToken.contains(':') &&
        !effectiveToken.contains('>') &&
        !effectiveToken.contains('<') &&
        !effectiveToken.contains('=')) {
      for (final p in _conditionPrefixes) {
        if (p.$1.startsWith(lowerEff) || p.$2.contains(effectiveToken)) {
          addUnique((
            DisplayedTag(group: 'prefix', name: p.$1, translated: p.$2),
            0,
          ));
        }
      }
    }

    // 1) 동기 메모리/번역 사전 매칭 즉시 표시 (네트워크 카탈로그 대기 없이 0ms 반응)
    final colonIdx = effectiveToken.indexOf(':');
    if (colonIdx > 0) {
      final g = effectiveToken.substring(0, colonIdx).trim().toLowerCase();
      final v = effectiveToken.substring(colonIdx + 1).trim();
      final syncMatches = HentaiIndex.searchTagsSync(v);
      for (final m in syncMatches) {
        if (result.length >= 35) break;
        final mg = (m.$1.group ?? '').toLowerCase();
        if (mg == g || (g == 'tag' && (mg == 'female' || mg == 'male'))) {
          addUnique(m);
        }
      }
    } else {
      final syncMatches = HentaiIndex.searchTagsSync(effectiveToken);
      for (final m in syncMatches) {
        if (result.length >= 35) break;
        addUnique(m);
      }
    }

    if (!mounted || reqId != _conditionReqId) return;
    if (result.isNotEmpty) {
      setState(() {
        _conditionSuggestions = result.take(35).toList();
      });
    }

    // 2) 비동기 카탈로그/DB 인덱스 보충
    try {
      await HentaiIndex.loadCountMapIfRequired();
      final matches = Settings.searchUseFuzzy.value
          ? await HentaiIndex.queryAutoCompleteFuzzy(
              effectiveToken,
              Settings.searchUseTranslated.value,
            )
          : await HentaiIndex.queryAutoComplete(
              effectiveToken,
              Settings.searchUseTranslated.value,
            );
      for (final m in matches) {
        if (result.length >= 35) break;
        addUnique(m);
      }
    } catch (_) {}

    if (!mounted || reqId != _conditionReqId) return;
    setState(() {
      _conditionSuggestions = result.take(35).toList();
    });
  }

  void _applyConditionSuggestion((DisplayedTag, int) info) {
    final text = _conditionController.text;
    final start = _conditionTokenStart.clamp(0, text.length);
    final end = _conditionTokenEnd.clamp(start, text.length);
    final negPrefix = _conditionHasNegative ? '-' : '';
    final tag = info.$1;

    String insertText;
    bool appendSpace;
    if (tag.group == 'prefix') {
      final name = tag.name ?? '';
      final noColon = name == 'page' || name == 'random';
      insertText = '$negPrefix$name${noColon ? '' : ':'}';
      appendSpace = name == 'random';
    } else if ((tag.group == 'page' || tag.group == 'id' || tag.group == 'date') &&
        (tag.name != null &&
            (tag.name!.startsWith('>') ||
                tag.name!.startsWith('<') ||
                tag.name!.startsWith('=')))) {
      insertText = '$negPrefix${tag.group}${tag.name}';
      appendSpace = false;
    } else {
      insertText = '$negPrefix${tag.getTag().replaceAll(' ', '_')}';
      appendSpace = true;
    }

    final after = text.substring(end);
    if (appendSpace && (after.isEmpty || !after.startsWith(' '))) {
      insertText = '$insertText ';
    }

    final nextText = text.substring(0, start) + insertText + after;
    final nextOffset = start + insertText.length;

    _conditionController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    if (!_conditionFocusNode.hasFocus && _conditionFocusNode.canRequestFocus) {
      _conditionFocusNode.requestFocus();
    }
    setState(() {
      _showConditionSuggestions = true;
    });
    unawaited(_updateConditionSuggestions());
  }

  static Color _tagGroupColor(String? group) {
    switch (group) {
      case 'female':
        return Colors.pink;
      case 'male':
        return Colors.blue;
      case 'prefix':
      case 'type':
      case 'page':
        return Colors.orange.shade700;
      case 'lang':
      case 'language':
        return Colors.teal;
      case 'series':
        return Colors.cyan.shade700;
      case 'character':
        return Colors.indigo;
      case 'artist':
      case 'group':
        return Colors.green.shade700;
      case 'uploader':
        return Colors.deepPurple;
      default:
        return Colors.grey.shade700;
    }
  }

  Widget _buildSuggestionChip((DisplayedTag, int) item) {
    final tag = item.$1;
    final count = item.$2;
    final color = _tagGroupColor(tag.group);
    final groupBadge = (tag.group?.isNotEmpty ?? false)
        ? tag.group![0].toUpperCase()
        : 'T';
    final isPrefix = tag.group == 'prefix';
    final rawName = isPrefix
        ? '${tag.name}${(tag.name == 'page' || tag.name == 'random') ? '' : ':'}'
        : tag.getTag();
    final trans = isPrefix
        ? (tag.translated ?? '')
        : (tag.name != null ? tag.getTranslated() : '');
    final showTrans = trans.isNotEmpty &&
        trans.toLowerCase() != (tag.name ?? '').toLowerCase();
    final labelText = showTrans
        ? (isPrefix ? '$rawName ($trans)' : '$rawName · $trans')
        : rawName;
    final negMark = _conditionHasNegative && !isPrefix ? '-' : '';
    final countText = count > 0 ? ' (${_formatCount(count)})' : '';

    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(14),
        onTap: () => _applyConditionSuggestion(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  groupBadge,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 230),
                child: Text(
                  '$negMark$labelText$countText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConditionSuggestionPanel(bool isDark, Color accent) {
    final bgColor = isDark
        ? Colors.grey.shade800.withValues(alpha: 0.72)
        : Colors.grey.shade100;
    final borderColor = isDark ? Colors.grey.shade700 : Colors.grey.shade300;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 13, color: accent),
              const SizedBox(width: 4),
              Text(
                _conditionActiveToken.trim().isEmpty
                    ? '필터 접두사 선택'
                    : '필터 태그 자동완성 (${_conditionSuggestions.length})',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                ),
              ),
              if (_conditionHasNegative) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '제외(-)',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              InkWell(
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _showConditionSuggestions = false),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 142),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children:
                    _conditionSuggestions.map(_buildSuggestionChip).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onConditionFocusChanged() {
    if (!mounted) return;
    if (_conditionFocusNode.hasFocus) {
      setState(() => _showConditionSuggestions = true);
      unawaited(_updateConditionSuggestions());
    } else {
      setState(() => _showConditionSuggestions = false);
    }
  }

  void _setViewMode(DialogueViewMode mode) {
    if (_viewMode == mode) return;
    _unfocusInputs();
    setState(() => _viewMode = mode);
    unawaited(
      Settings.messageSearchGridMode.setValue(mode == DialogueViewMode.grid),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _conditionDebounce?.cancel();
    _conditionFocusNode.removeListener(_onConditionFocusChanged);
    _dialogueFocusNode.dispose();
    _conditionFocusNode.dispose();
    _dialogueController.dispose();
    _conditionController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {
        _progress = MessageCorpusManager.instance.progressSnapshot;
      });
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _resolveHitArticles(List<rust_msg.MobileMessageHit> hits) async {
    final neededIds = hits
        .map((h) => h.articleId)
        .where((id) => !_articleCache.containsKey(id))
        .toSet()
        .toList();
    if (neededIds.isEmpty) return;

    try {
      final dbResults = await QueryManager.queryIds(neededIds);
      for (final qr in dbResults) {
        _articleCache[qr.id()] = qr;
      }
    } catch (_) {}

    final stillMissing =
        neededIds.where((id) => !_articleCache.containsKey(id)).toList();
    if (stillMissing.isNotEmpty) {
      final cachedBatch =
          await HybridLoader.getCachedMetadataBatch(stillMissing);
      for (final entry in cachedBatch.entries) {
        _articleCache[entry.key] = entry.value;
      }
    }

    if (mounted) setState(() {});

    final needNetwork = neededIds
        .where((id) => !_articleCache.containsKey(id))
        .take(20)
        .toList();
    if (needNetwork.isNotEmpty) {
      await Future.wait(
        needNetwork.map((id) async {
          try {
            final res = await HybridLoader.idQueryHitomiFast(id)
                .timeout(const Duration(seconds: 3));
            if (res.result.length > 1) {
              _articleCache[id] = res;
              HybridLoader.cacheMetadata(res);
            }
          } catch (_) {}
        }),
      );
      if (mounted) setState(() {});
    }
  }

  Future<List<rust_msg.MobileMessageHit>> _filterHitsByPostCondition(
    List<rust_msg.MobileMessageHit> hits,
    String postCondition,
  ) async {
    if (hits.isEmpty) return hits;
    final lowerCond = postCondition.toLowerCase();
    final needsPageCount = lowerCond.contains('page');

    final uniqueIds = hits.map((h) => h.articleId).toSet().toList();
    final missingIds =
        uniqueIds.where((id) => !_articleCache.containsKey(id)).toList();

    if (missingIds.isNotEmpty) {
      try {
        final cached = await HybridLoader.getCachedMetadataBatch(missingIds);
        _articleCache.addAll(cached);
      } catch (_) {}
    }

    final toFetch = uniqueIds.where((id) {
      final qr = _articleCache[id];
      if (qr == null) return true;
      if (needsPageCount && LocalArticleFilter.extractPageCount(qr) == null) {
        return true;
      }
      return false;
    }).toList();

    const batchSize = 12;
    for (var i = 0; i < toFetch.length; i += batchSize) {
      final end = math.min(i + batchSize, toFetch.length);
      final chunk = toFetch.sublist(i, end);
      await Future.wait(
        chunk.map((id) async {
          try {
            var qr = _articleCache[id];
            if (qr == null) {
              final fast = await HybridLoader.idQueryHitomiFast(id)
                  .timeout(const Duration(seconds: 3));
              if (fast.result.length > 1) {
                qr = fast;
              }
            }
            if (needsPageCount &&
                (qr == null ||
                    LocalArticleFilter.extractPageCount(qr) == null)) {
              final info = await HentaiManager.tryFetchHitomiGalleryInfo(id)
                  .timeout(const Duration(seconds: 3));
              if (info.isNotEmpty) {
                final merged = Map<String, dynamic>.from(
                  qr?.result ?? <String, dynamic>{'Id': id},
                );
                for (final e in info.entries) {
                  if (e.value != null) merged[e.key] = e.value;
                }
                qr = QueryResult(result: merged);
              }
            }
            if (qr != null && qr.result.length > 1) {
              _articleCache[id] = qr;
              HybridLoader.cacheMetadata(qr);
            }
          } catch (_) {}
        }),
      );
    }

    final allowedIds = <int>{};
    for (final id in uniqueIds) {
      final qr = _articleCache[id];
      if (qr == null) continue;
      if (LocalArticleFilter.filter([qr], postCondition).isNotEmpty) {
        allowedIds.add(id);
      }
    }
    return hits.where((h) => allowedIds.contains(h.articleId)).toList();
  }

  Future<void> _runSearch({
    bool resetTake = true,
    bool sortSwitchOnly = false,
  }) async {
    final mgr = MessageCorpusManager.instance;
    if (!mgr.isReady) {
      showToast(
        level: ToastLevel.warning,
        message: '설정에서 경량 대사 검색 엔진을 먼저 활성화해 주세요.',
      );
      return;
    }

    final query = _dialogueController.text.trim();
    if (query.isEmpty) {
      showToast(
        level: ToastLevel.warning,
        message: '검색할 대사를 입력해 주세요.',
      );
      if (_dialogueFocusNode.canRequestFocus) {
        _dialogueFocusNode.requestFocus();
      }
      return;
    }

    if (resetTake) {
      _take = _pageStep;
    }

    _unfocusInputs();

    if (!sortSwitchOnly) {
      setState(() {
        _searching = true;
        _statusMessage = null;
        _progress = mgr.progressSnapshot;
      });
      _startPolling();
    }

    try {
      List<int>? whitelistIds = widget.scopedArticleIds;
      int? idMin;
      int? idMax;
      Set<int> excludedIds = const <int>{};
      String? postFilterCondition;

      if (whitelistIds == null && _conditionController.text.trim().isNotEmpty) {
        final filterRes = await mgr.resolveArticleFilter(
          _conditionController.text.trim(),
        );
        if (!mounted) return;
        if (filterRes.errorMessage != null) {
          setState(() {
            _hits = const [];
            _totalMatched = 0;
            _statusMessage = filterRes.errorMessage;
          });
          return;
        }
        if (filterRes.isEmptyMatch) {
          setState(() {
            _hits = const [];
            _totalMatched = 0;
            _statusMessage = '입력한 작품 조건에 일치하는 한국어 작품이 없습니다.';
          });
          return;
        }
        whitelistIds = filterRes.whitelistIds;
        idMin = filterRes.idMin;
        idMax = filterRes.idMax;
        excludedIds = filterRes.excludedIds;
        postFilterCondition = filterRes.postFilterCondition;
      }

      final needsPostFilter =
          postFilterCondition != null || excludedIds.isNotEmpty;
      final requestTake =
          needsPostFilter ? math.max(_take, 2000).clamp(1, _maxTake) : _take;

      final res = await mgr.searchGlobalEx(
        query: query,
        mode: _mode,
        sortMode: _sortMode,
        take: requestTake,
        whitelistIds: whitelistIds,
        idMin: idMin,
        idMax: idMax,
      );

      var finalHits = res.hits;
      var finalTotalMatched = res.totalMatched.toInt();

      if (excludedIds.isNotEmpty) {
        finalHits =
            finalHits.where((h) => !excludedIds.contains(h.articleId)).toList();
        finalTotalMatched = finalHits.length;
      }

      if (postFilterCondition != null && finalHits.isNotEmpty) {
        finalHits =
            await _filterHitsByPostCondition(finalHits, postFilterCondition);
        finalTotalMatched = finalHits.length;
      }

      if (finalHits.length > _take) {
        finalHits = finalHits.sublist(0, _take);
      }

      if (!mounted) return;
      setState(() {
        _totalMatched = finalTotalMatched;
        _hits = finalHits;
        if (finalHits.isEmpty) {
          _statusMessage = '일치하는 대사를 찾지 못했습니다.';
        }
      });
      unawaited(_resolveHitArticles(finalHits));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        _statusMessage = msg.contains('cancelled')
            ? '대사 검색이 취소되었습니다.'
            : '검색 오류: $msg';
      });
    } finally {
      _stopPolling();
      if (mounted) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  Future<void> _openHitInViewer(rust_msg.MobileMessageHit hit) {
    return _runWithSuppressedInputFocus(() async {
      try {
        var qr = _articleCache[hit.articleId];
        qr ??= await HentaiManager.idQueryWeb('${hit.articleId}');
        _articleCache[hit.articleId] = qr;
        await getImageProvider(qr);
        if (!mounted) return;
        await showViewer(context, hit.articleId, hit.page);
      } catch (e) {
        showToast(level: ToastLevel.error, message: '뷰어를 열지 못했습니다: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Settings.themeWhat.value;
    final accent = Settings.majorColor.value;

    return Scaffold(
      backgroundColor: Palette.themeColor,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 48,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: isDark ? Colors.white : Colors.black87,
          ),
          onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.scopeLabel != null
              ? '범위 대사 검색 · ${widget.scopeLabel}'
              : '한국어 대사 검색',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildViewModeButton(
                    mode: DialogueViewMode.detail,
                    icon: MdiIcons.formatListText,
                    tooltip: '디테일 뷰',
                    isDark: isDark,
                    accent: accent,
                  ),
                  _buildViewModeButton(
                    mode: DialogueViewMode.grid,
                    icon: Icons.grid_view_rounded,
                    tooltip: '그리드 뷰',
                    isDark: isDark,
                    accent: accent,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _buildControls(isDark, accent),
            if (_searching) _buildProgressBanner(accent),
            if (!_searching && _hits.isNotEmpty)
              _buildResultSummary(isDark, accent),
            Expanded(child: _buildResultsList(isDark, accent)),
          ],
        ),
      ),
    );
  }

  Widget _buildViewModeButton({
    required DialogueViewMode mode,
    required IconData icon,
    required String tooltip,
    required bool isDark,
    required Color accent,
  }) {
    final selected = _viewMode == mode;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _setViewMode(mode),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Icon(
              icon,
              size: 18,
              color: selected
                  ? Colors.white
                  : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResultSummary(bool isDark, Color accent) {
    final totalStr = _formatCount(_totalMatched);
    final shownStr = _formatCount(_hits.length);
    final sortLabel = switch (_sortMode) {
      DialogueSortMode.relevance => '일치도순',
      DialogueSortMode.latest => '최신순',
      DialogueSortMode.popular => '인기순',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Row(
        children: [
          Icon(MdiIcons.textSearch, size: 15, color: accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _totalMatched > _hits.length
                  ? '찾은 대사 $totalStr건 중 $shownStr건 표시 · $sortLabel'
                  : '찾은 대사 $totalStr건 · $sortLabel',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(bool isDark, Color accent) {
    final typoHint = Settings.enableHangulTypoRestore.value
        ? HangulAutoRestorer.tryRestoreKoreanWord(_dialogueController.text.trim())
        : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? (Settings.themeBlack.value
                ? Palette.blackThemeBackground
                : Colors.grey.shade900)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _dialogueController,
                  focusNode: _dialogueFocusNode,
                  canRequestFocus: _suppressInputFocusCount == 0,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _runSearch(),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    prefixIcon: Icon(MdiIcons.commentTextOutline, color: accent, size: 20),
                    hintText: '한국어 대사 입력 (영타 자동 매칭)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: _searching ? null : () => _runSearch(),
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('검색'),
                ),
              ),
            ],
          ),
          if (typoHint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: InkWell(
                onTap: () => setState(() => _dialogueController.text = typoHint),
                child: Text(
                  '영타 복원 인식됨: "$typoHint"',
                  style: TextStyle(fontSize: 12, color: accent),
                ),
              ),
            ),
          if (widget.scopedArticleIds == null) ...[
            const SizedBox(height: 6),
            TextField(
              controller: _conditionController,
              focusNode: _conditionFocusNode,
              canRequestFocus: _suppressInputFocusCount == 0,
              textInputAction: TextInputAction.search,
              onTap: () {
                if (!_showConditionSuggestions) {
                  setState(() => _showConditionSuggestions = true);
                }
                unawaited(_updateConditionSuggestions());
              },
              onChanged: (_) => _scheduleConditionSuggestions(),
              onSubmitted: (_) => _runSearch(),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                prefixIcon: const Icon(Icons.tune, size: 17),
                suffixIcon: _conditionController.text.isNotEmpty
                    ? IconButton(
                        tooltip: '조건 지우기',
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _conditionController.clear();
                          setState(() {});
                          if (_conditionFocusNode.hasFocus) {
                            unawaited(_updateConditionSuggestions());
                          }
                        },
                      )
                    : null,
                hintText: '작품 조건 (예: artist:이름 female:elf page>30)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            if (_showConditionSuggestions && _conditionSuggestions.isNotEmpty)
              _buildConditionSuggestionPanel(isDark, accent),
          ],
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('포함', style: TextStyle(fontSize: 11.5)),
                  selected: _mode == DialogueSearchMode.contains,
                  selectedColor: accent.withValues(alpha: 0.25),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) =>
                      setState(() => _mode = DialogueSearchMode.contains),
                ),
                const SizedBox(width: 5),
                ChoiceChip(
                  label: const Text('유사도', style: TextStyle(fontSize: 11.5)),
                  selected: _mode == DialogueSearchMode.similar,
                  selectedColor: accent.withValues(alpha: 0.25),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) =>
                      setState(() => _mode = DialogueSearchMode.similar),
                ),
                const SizedBox(width: 10),
                Container(width: 1, height: 18, color: Colors.grey.withValues(alpha: 0.35)),
                const SizedBox(width: 10),
                for (final entry in const [
                  (DialogueSortMode.relevance, '일치도순'),
                  (DialogueSortMode.latest, '최신순'),
                  (DialogueSortMode.popular, '인기순'),
                ]) ...[
                  ChoiceChip(
                    label: Text(entry.$2, style: const TextStyle(fontSize: 11.5)),
                    selected: _sortMode == entry.$1,
                    selectedColor: accent.withValues(alpha: 0.25),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      if (_sortMode == entry.$1) return;
                      setState(() => _sortMode = entry.$1);
                      if (_dialogueController.text.trim().isNotEmpty) {
                        _runSearch(resetTake: false, sortSwitchOnly: true);
                      }
                    },
                  ),
                  const SizedBox(width: 5),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBanner(Color accent) {
    final p = _progress;
    final planned = p?.plannedRecords.toInt() ?? 0;
    final scanned = p?.scannedRecords.toInt() ?? 0;
    final ratio = planned > 0 ? (scanned / planned).clamp(0.0, 1.0) : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 2.2,
              color: accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              planned > 0
                  ? '대사 스캔 중... ${(ratio! * 100).toStringAsFixed(1)}% ($scanned / $planned)'
                  : '대사 검색 준비 중...',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: MessageCorpusManager.instance.cancelActiveSearch,
            child: const Text(
              '취소',
              style: TextStyle(fontSize: 12.5, color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showPagePreviewDialog(
    rust_msg.MobileMessageHit hit,
    String title,
  ) {
    return _runWithSuppressedInputFocus(() async {
      final imgList = await _getImageListCached(hit.articleId);
      final headers = await _getHeaderCached(hit.articleId);
      String? pageUrl;
      String? fallbackUrl;
      if (hit.page >= 0 && hit.page < imgList.urls.length) {
        pageUrl = imgList.urls[hit.page];
        if (hit.page < imgList.bigThumbnails.length) {
          fallbackUrl = imgList.bigThumbnails[hit.page];
        }
      } else if (hit.page >= 0 && hit.page < imgList.bigThumbnails.length) {
        pageUrl = imgList.bigThumbnails[hit.page];
      }
      if (!mounted) return;
      if (pageUrl == null || pageUrl.isEmpty) {
        await _openHitInViewer(hit);
        return;
      }

      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$title · p.${hit.page + 1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 3.5,
                  child: _DialoguePreviewImageWithBox(
                    imageUrl: pageUrl!,
                    fallbackUrl: fallbackUrl,
                    headers: headers,
                    rect: hit.rect,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hit.rawText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Settings.majorColor.value,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openHitInViewer(hit);
                      },
                      child: const Text('뷰어 열기'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildResultsList(bool isDark, Color accent) {
    if (_statusMessage != null && _hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _statusMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    if (_hits.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '한국어 대사를 입력하고 검색 버튼을 눌러보세요.\n항목을 터치하면 해당 대사 페이지로 즉시 이동합니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
      );
    }

    final hasMore = _totalMatched > _hits.length && _take < _maxTake;
    final remaining = _totalMatched - _hits.length;

    if (_viewMode == DialogueViewMode.grid) {
      return _buildGridResults(
        isDark: isDark,
        hasMore: hasMore,
        remaining: remaining,
      );
    }

    return _buildDetailResults(
      isDark: isDark,
      accent: accent,
      hasMore: hasMore,
      remaining: remaining,
    );
  }

  Widget _buildLoadMoreButton(int remaining) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.expand_more),
          label: Text(
            '결과 더 보기 (+$_pageStep건, 남은 ${_formatCount(remaining)}건)',
          ),
          onPressed: _searching
              ? null
              : () {
                  setState(() {
                    _take = (_take + _pageStep).clamp(_pageStep, _maxTake);
                  });
                  _runSearch(resetTake: false);
                },
        ),
      ),
    );
  }

  (String title, String artists) _resolveHitMeta(rust_msg.MobileMessageHit hit) {
    final qr = _articleCache[hit.articleId];
    final title = (qr?.title().toString().trim().isNotEmpty ?? false)
        ? qr!.title().toString()
        : '작품 #${hit.articleId}';
    final artists = (qr?.artists().toString() ?? '')
        .split('|')
        .where((s) => s.trim().isNotEmpty)
        .join(', ');
    return (title, artists);
  }

  Widget _buildDetailResults({
    required bool isDark,
    required Color accent,
    required bool hasMore,
    required int remaining,
  }) {
    final itemCount = _hits.length + (hasMore ? 1 : 0);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 20),
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: itemCount,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (hasMore && index == _hits.length) {
          return _buildLoadMoreButton(remaining);
        }

        final hit = _hits[index];
        final qr = _articleCache[hit.articleId];
        final (title, artists) = _resolveHitMeta(hit);

        return Material(
          color: isDark
              ? (Settings.themeBlack.value
                  ? Palette.blackThemeBackground
                  : Colors.grey.shade900)
              : Colors.white,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _openHitInViewer(hit),
            onLongPress: () async {
              final targetQr = qr ?? QueryResult(result: {'Id': hit.articleId});
              await _runWithSuppressedInputFocus(
                () => showArticleInfoRaw(
                  context: context,
                  queryResult: targetQr,
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => _showPagePreviewDialog(hit, title),
                    child: _DialoguePageThumbnail(
                      articleId: hit.articleId,
                      page: hit.page,
                      imageListFuture: _getImageListCached(hit.articleId),
                      headerFuture: _getHeaderCached(hit.articleId),
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'p.${hit.page + 1}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '#${hit.articleId}',
                              style: const TextStyle(fontSize: 11.5, color: Colors.grey),
                            ),
                            const Spacer(),
                            Text(
                              '일치 ${hit.matchScore.toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: hit.matchScore >= 99.5
                                    ? Colors.green
                                    : Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          hit.rawText,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          artists.isNotEmpty ? '$title · $artists' : title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGridResults({
    required bool isDark,
    required bool hasMore,
    required int remaining,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 900 ? 4 : (width >= 600 ? 3 : 2);

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.56,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildGridCard(_hits[index], isDark),
                  childCount: _hits.length,
                ),
              ),
            ),
            if (hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildLoadMoreButton(remaining),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildGridCard(rust_msg.MobileMessageHit hit, bool isDark) {
    final qr = _articleCache[hit.articleId];
    final (title, artists) = _resolveHitMeta(hit);

    return Material(
      color: isDark
          ? (Settings.themeBlack.value
              ? Palette.blackThemeBackground
              : Colors.grey.shade900)
          : Colors.white,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openHitInViewer(hit),
        onLongPress: () async {
          final targetQr = qr ?? QueryResult(result: {'Id': hit.articleId});
          await _runWithSuppressedInputFocus(
            () => showArticleInfoRaw(
              context: context,
              queryResult: targetQr,
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _showPagePreviewDialog(hit, title),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _DialoguePageThumbnail(
                      articleId: hit.articleId,
                      page: hit.page,
                      imageListFuture: _getImageListCached(hit.articleId),
                      headerFuture: _getHeaderCached(hit.articleId),
                      isDark: isDark,
                      width: null,
                      height: null,
                      borderRadius: BorderRadius.zero,
                      memCacheWidth: 420,
                    ),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'p.${hit.page + 1}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: hit.matchScore >= 99.5
                              ? Colors.green.withValues(alpha: 0.85)
                              : Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${hit.matchScore.toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hit.rawText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    artists.isNotEmpty ? '$title · $artists' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark
                          ? Colors.grey.shade400
                          : Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialoguePageThumbnail extends StatelessWidget {
  final int articleId;
  final int page;
  final Future<ImageList> imageListFuture;
  final Future<Map<String, String>> headerFuture;
  final bool isDark;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final int memCacheWidth;

  const _DialoguePageThumbnail({
    required this.articleId,
    required this.page,
    required this.imageListFuture,
    required this.headerFuture,
    required this.isDark,
    this.width = 70,
    this.height = 98,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
    this.memCacheWidth = 210,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        width: width,
        height: height,
        color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        child: FutureBuilder<(ImageList, Map<String, String>)>(
          future: Future.wait([imageListFuture, headerFuture]).then(
            (res) => (res[0] as ImageList, res[1] as Map<String, String>),
          ),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final imgList = snap.data!.$1;
            final headers = snap.data!.$2;
            String? url;
            if (page >= 0 && page < imgList.urls.length) {
              url = imgList.urls[page];
            } else if (page >= 0 && page < imgList.bigThumbnails.length) {
              url = imgList.bigThumbnails[page];
            } else if (imgList.smallThumbnails != null &&
                page >= 0 &&
                page < imgList.smallThumbnails!.length) {
              url = imgList.smallThumbnails![page];
            }
            if (url == null || url.isEmpty) {
              return const Center(
                child: Icon(Icons.image_not_supported_outlined, size: 22),
              );
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: url,
                  httpHeaders: headers,
                  fit: BoxFit.cover,
                  memCacheWidth: memCacheWidth,
                  placeholder: (_, _) => const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                  ),
                  errorWidget: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 20),
                  ),
                ),
                Positioned(
                  right: 3,
                  bottom: 3,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.zoom_in,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 원본 이미지 픽셀 좌표(`[x1, y1, x2, y2]`)를 화면 표시 크기(`displayWidth x displayHeight`)로 변환합니다.
Rect? computeDialogueOverlayRect({
  required List<double> rect,
  required double naturalWidth,
  required double naturalHeight,
  required double displayWidth,
  required double displayHeight,
  double padding = 4.0,
}) {
  if (rect.length < 4 ||
      naturalWidth <= 0 ||
      naturalHeight <= 0 ||
      displayWidth <= 0 ||
      displayHeight <= 0) {
    return null;
  }
  final x1 = rect[0];
  final y1 = rect[1];
  final x2 = rect[2];
  final y2 = rect[3];
  if (x2 <= x1 || y2 <= y1) return null;

  final scaleX = displayWidth / naturalWidth;
  final scaleY = displayHeight / naturalHeight;

  final left = (x1 * scaleX - padding).clamp(0.0, displayWidth);
  final top = (y1 * scaleY - padding).clamp(0.0, displayHeight);
  final right = (x2 * scaleX + padding).clamp(left, displayWidth);
  final bottom = (y2 * scaleY + padding).clamp(top, displayHeight);

  if (right - left < 2.0 || bottom - top < 2.0) {
    return null;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

class _DialoguePreviewImageWithBox extends StatefulWidget {
  final String imageUrl;
  final String? fallbackUrl;
  final Map<String, String> headers;
  final List<double> rect;

  const _DialoguePreviewImageWithBox({
    required this.imageUrl,
    this.fallbackUrl,
    required this.headers,
    required this.rect,
  });

  @override
  State<_DialoguePreviewImageWithBox> createState() =>
      _DialoguePreviewImageWithBoxState();
}

class _DialoguePreviewImageWithBoxState
    extends State<_DialoguePreviewImageWithBox> {
  late CachedNetworkImageProvider _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _naturalSize;
  bool _failed = false;
  bool _triedFallback = false;

  @override
  void initState() {
    super.initState();
    _resolveUrl(widget.imageUrl);
  }

  @override
  void didUpdateWidget(covariant _DialoguePreviewImageWithBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.fallbackUrl != widget.fallbackUrl) {
      _triedFallback = false;
      _resolveUrl(widget.imageUrl);
    }
  }

  void _detachStream() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void _resolveUrl(String url) {
    _detachStream();
    _naturalSize = null;
    _failed = false;
    _provider = CachedNetworkImageProvider(url, headers: widget.headers);
    final stream = _provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _naturalSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          _failed = false;
        });
      },
      onError: (_, _) {
        if (!mounted) return;
        if (!_triedFallback &&
            widget.fallbackUrl != null &&
            widget.fallbackUrl!.isNotEmpty &&
            widget.fallbackUrl != url) {
          _triedFallback = true;
          _resolveUrl(widget.fallbackUrl!);
          return;
        }
        setState(() {
          _failed = true;
        });
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  void dispose() {
    _detachStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const SizedBox(
        height: 160,
        child: Center(child: Icon(Icons.broken_image_outlined)),
      );
    }
    final natural = _naturalSize;
    if (natural == null || natural.width <= 0 || natural.height <= 0) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : natural.width;
        final scale =
            (constraints.maxHeight.isFinite && constraints.maxHeight > 0)
                ? math.min(
                    maxW / natural.width,
                    constraints.maxHeight / natural.height,
                  )
                : (maxW / natural.width);
        final displayW = natural.width * scale;
        final displayH = natural.height * scale;
        final boxRect = computeDialogueOverlayRect(
          rect: widget.rect,
          naturalWidth: natural.width,
          naturalHeight: natural.height,
          displayWidth: displayW,
          displayHeight: displayH,
        );

        return Center(
          child: SizedBox(
            width: displayW,
            height: displayH,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image(
                    image: _provider,
                    fit: BoxFit.fill,
                  ),
                ),
                if (boxRect != null)
                  Positioned(
                    left: boxRect.left,
                    top: boxRect.top,
                    width: boxRect.width,
                    height: boxRect.height,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.10),
                          border: Border.all(
                            color: Colors.red,
                            width: 2.5,
                          ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
