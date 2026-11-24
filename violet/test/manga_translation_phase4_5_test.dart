// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/manga_translation_prefetcher.dart';
import 'package:violet/component/manga_translation_profile.dart';
import 'package:violet/src/rust/api/manga_vision.dart';

void main() {
  TranslatedPageBundle fakeBundle(int pageIndex) {
    return TranslatedPageBundle(
      pageIndex: pageIndex,
      preprocessed: PreprocessedMangaPage(
        width: 100,
        height: 100,
        origWidth: 100,
        origHeight: 100,
        lumaBytes: Uint8List(100 * 100),
        latencyMs: 1.0,
      ),
      timing: MangaTranslationStageTiming(
        pageIndex: pageIndex,
        preprocessMs: 1.0,
        ocrDetectMs: 2.0,
        ocrRecMs: 3.0,
        zeroAiEraseMs: 1.0,
        translateMs: 10.0,
        typesetMs: 1.0,
      ),
    );
  }

  test('Phase 4: LRU cache bounds memory across 20 sequential pages', () async {
    final prefetcher = MangaTranslationPrefetcher(
      profile: DeviceTranslationProfile.lowRamLegacy, // maxCachedPages = 6
      processorOverride: (pageIndex, _, __) async => fakeBundle(pageIndex),
    );

    for (var p = 0; p < 20; p++) {
      final res = await prefetcher.processPage(
        pageIndex: p,
        imageLoader: (_) async => Uint8List.fromList([1, 2, 3]),
      );
      expect(res?.pageIndex, p);
      expect(prefetcher.cachedCount <= 6, isTrue);
    }

    expect(prefetcher.cachedCount, 6);
    expect(prefetcher.hasCached(0), isFalse);
    expect(prefetcher.hasCached(19), isTrue);
  });

  test('Phase 4: N+1 background prefetch caches next page automatically', () async {
    final prefetcher = MangaTranslationPrefetcher(
      profile: DeviceTranslationProfile.flagshipCpu,
      processorOverride: (pageIndex, _, __) async => fakeBundle(pageIndex),
    );

    await prefetcher.processPage(
      pageIndex: 0,
      imageLoader: (_) async => Uint8List.fromList([1, 2, 3]),
    );
    prefetcher.prefetchNext(
      currentPage: 0,
      maxPage: 10,
      imageLoader: (_) async => Uint8List.fromList([1, 2, 3]),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(prefetcher.hasCached(1), isTrue);
  });

  test('Phase 5: DeviceTranslationProfile presets and 6-stage totalMs', () {
    expect(DeviceTranslationProfile.lowRamLegacy.numThreads, 2);
    expect(DeviceTranslationProfile.lowRamLegacy.maxLongEdge, 1280);
    expect(DeviceTranslationProfile.flagshipNpu.useNpuIfAvailable, isTrue);

    final timing = fakeBundle(0).timing;
    expect(timing.totalMs, 18.0);
  });
}
