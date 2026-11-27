// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:violet/component/manga_translation_pipeline.dart';
import 'package:violet/component/manga_translation_profile.dart';
import 'package:violet/src/rust/api/manga_vision.dart' as rust_vision;

class TranslatedPageBundle {
  final int pageIndex;
  final rust_vision.PreprocessedMangaPage preprocessed;
  final MangaTranslationStageTiming timing;

  const TranslatedPageBundle({
    required this.pageIndex,
    required this.preprocessed,
    required this.timing,
  });
}

typedef PageProcessorFn = Future<TranslatedPageBundle?> Function(
  int pageIndex,
  Uint8List imageBytes,
  DeviceTranslationProfile profile,
);

/// Phase 4: 페이지 단위 LRU 캐싱 및 `N+1` 백그라운드 프리페칭 매니저
/// - 연속 페이지 넘김 시 OOM 방지를 위해 `profile.maxCachedPages` 상한 유지
/// - 동일 페이지 중복 연산 방지를 위한 in-flight Future 디듀플리케이션
class MangaTranslationPrefetcher {
  final DeviceTranslationProfile profile;
  final PageProcessorFn? processorOverride;

  final LinkedHashMap<int, TranslatedPageBundle> _lruCache = LinkedHashMap();
  final Map<int, Future<TranslatedPageBundle?>> _inFlight = {};

  MangaTranslationPrefetcher({
    required this.profile,
    this.processorOverride,
  });

  int get cachedCount => _lruCache.length;
  bool hasCached(int pageIndex) => _lruCache.containsKey(pageIndex);

  TranslatedPageBundle? getCached(int pageIndex) {
    final hit = _lruCache.remove(pageIndex);
    if (hit != null) {
      // 최근 접근 항목을 맨 뒤로 이동 (LRU 갱신)
      _lruCache[pageIndex] = hit;
    }
    return hit;
  }

  Future<TranslatedPageBundle?> processPage({
    required int pageIndex,
    required Future<Uint8List?> Function(int pageIndex) imageLoader,
  }) {
    final cached = getCached(pageIndex);
    if (cached != null) {
      return Future.value(cached);
    }

    final existing = _inFlight[pageIndex];
    if (existing != null) {
      return existing;
    }

    final future = _runPage(pageIndex, imageLoader).whenComplete(() {
      _inFlight.remove(pageIndex);
    });
    _inFlight[pageIndex] = future;
    return future;
  }

  /// 현재 페이지 `N`을 읽는 동안 백그라운드에서 `N+1` 페이지를 미리 처리
  void prefetchNext({
    required int currentPage,
    required int maxPage,
    required Future<Uint8List?> Function(int pageIndex) imageLoader,
  }) {
    final nextPage = currentPage + 1;
    if (nextPage < 0 || nextPage >= maxPage) return;
    if (hasCached(nextPage) || _inFlight.containsKey(nextPage)) return;
    unawaited(processPage(pageIndex: nextPage, imageLoader: imageLoader));
  }

  Future<TranslatedPageBundle?> _runPage(
    int pageIndex,
    Future<Uint8List?> Function(int pageIndex) imageLoader,
  ) async {
    final bytes = await imageLoader(pageIndex);
    if (bytes == null || bytes.isEmpty) return null;

    final bundle = processorOverride != null
        ? await processorOverride!(pageIndex, bytes, profile)
        : await _defaultProcess(pageIndex, bytes);

    if (bundle != null) {
      _insertWithEviction(pageIndex, bundle);
      bundle.timing.logSummary();
    }
    return bundle;
  }

  Future<TranslatedPageBundle?> _defaultProcess(
    int pageIndex,
    Uint8List bytes,
  ) async {
    final prep = await MangaTranslationPipeline.instance.preprocessGrayscale(
      bytes,
      maxLongEdge: profile.maxLongEdge,
    );
    if (prep == null) return null;

    return TranslatedPageBundle(
      pageIndex: pageIndex,
      preprocessed: prep,
      timing: MangaTranslationStageTiming(
        pageIndex: pageIndex,
        preprocessMs: prep.latencyMs,
        ocrDetectMs: 0.0,
        ocrRecMs: 0.0,
        zeroAiEraseMs: 0.0,
        translateMs: 0.0,
        typesetMs: 0.0,
      ),
    );
  }

  void _insertWithEviction(int pageIndex, TranslatedPageBundle bundle) {
    _lruCache.remove(pageIndex);
    _lruCache[pageIndex] = bundle;
    while (_lruCache.length > profile.maxCachedPages) {
      _lruCache.remove(_lruCache.keys.first);
    }
  }

  void clear() {
    _lruCache.clear();
    _inFlight.clear();
  }
}
