// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/download/download_id_parser.dart';

void main() {
  group('parseDownloadIds', () {
    test('parses single numeric id', () {
      final result = parseDownloadIds('1234567');
      expect(result.validIds, ['1234567']);
      expect(result.duplicateInputIds, isEmpty);
      expect(result.invalidTokens, isEmpty);
      expect(result.hasErrors, isFalse);
      expect(result.isEmpty, isFalse);
    });

    test('parses comma and space separated ids', () {
      final result = parseDownloadIds('100, 200');
      expect(result.validIds, ['100', '200']);
      expect(result.duplicateInputIds, isEmpty);
      expect(result.invalidTokens, isEmpty);
    });

    test('parses tight commas, multiple spaces, newlines, and trailing commas', () {
      final result = parseDownloadIds(' 100,200  300\n400,\r\n500, ');
      expect(result.validIds, ['100', '200', '300', '400', '500']);
      expect(result.duplicateInputIds, isEmpty);
      expect(result.invalidTokens, isEmpty);
    });

    test('deduplicates repeated ids while preserving order', () {
      final result = parseDownloadIds('100, 200, 100, 300, 200');
      expect(result.validIds, ['100', '200', '300']);
      expect(result.duplicateInputIds, ['100', '200']);
      expect(result.invalidTokens, isEmpty);
    });

    test('detects invalid non-numeric tokens', () {
      final result = parseDownloadIds('100, 20a, -5, 200');
      expect(result.validIds, ['100', '200']);
      expect(result.invalidTokens, ['20a', '-5']);
      expect(result.hasErrors, isTrue);
    });

    test('handles empty or delimiter-only input', () {
      final result = parseDownloadIds('  , \n , ');
      expect(result.validIds, isEmpty);
      expect(result.invalidTokens, isEmpty);
      expect(result.isEmpty, isTrue);
    });
  });
}
