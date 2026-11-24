// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/src/rust/api/translation.dart';

void main() {
  group('Rust Manga Translation Native Model Tests', () {
    test('MangaTranslationResult fields verification', () {
      const result = MangaTranslationResult(
        originalText: 'らいじょぶ らいじょぶ…',
        translatedText: '난 괜찮아, 난 괜찮아...',
        intermediateEnglish: "I'm fine, I'm fine...",
        normalizedSource: 'だいじょうぶ だいじょうぶ…',
        isResolvedByDictionary: true,
        translationTier: 'Violet Rust Native (Sugoi V4 INT8)',
        latencyMs: 86.4,
      );

      expect(result.originalText, equals('らいじょぶ らいじょぶ…'));
      expect(result.translatedText, equals('난 괜찮아, 난 괜찮아...'));
      expect(result.intermediateEnglish, equals("I'm fine, I'm fine..."));
      expect(result.normalizedSource, equals('だいじょうぶ だいじょうぶ…'));
      expect(result.isResolvedByDictionary, isTrue);
      expect(result.translationTier, contains('Rust Native'));
      expect(result.latencyMs, equals(86.4));
    });

    test('MangaPageTranslationReport aggregate verification', () {
      const item1 = MangaTranslationResult(
        originalText: 'らいじょぶ らいじょぶ…',
        translatedText: '난 괜찮아, 난 괜찮아...',
        intermediateEnglish: "I'm fine, I'm fine...",
        normalizedSource: 'だいじょうぶ だいじょうぶ…',
        isResolvedByDictionary: true,
        translationTier: 'Violet Rust Native',
        latencyMs: 86.0,
      );
      const item2 = MangaTranslationResult(
        originalText: 'あ゛ぁ゛っ',
        translatedText: '아아아아아아아아아아',
        intermediateEnglish: 'Aaaaaaaaaaaaa',
        normalizedSource: 'ああああああ',
        isResolvedByDictionary: true,
        translationTier: 'Violet Rust Native',
        latencyMs: 24.0,
      );

      const report = MangaPageTranslationReport(
        results: [item1, item2],
        totalLatencyMs: 110.0,
      );

      expect(report.results.length, equals(2));
      expect(report.results[0].translatedText, equals('난 괜찮아, 난 괜찮아...'));
      expect(report.results[1].translatedText, equals('아아아아아아아아아아'));
      expect(report.totalLatencyMs, equals(110.0));
    });
  });
}
