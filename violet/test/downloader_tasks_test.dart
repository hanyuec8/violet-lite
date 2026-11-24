// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/downloadable.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/settings/settings.dart';

void main() {
  group('Download FileNameFormat & Online Metadata Snapshot', () {
    test('formats download path safely with special characters stripped', () {
      final fmt = FileNameFormat(
        extractor: 'hentai',
        id: '123456',
        title: 'Test: Title / With? Invalid*Chars',
        artist: 'artist_a',
        filenameWithoutExtension: '001',
        extension: 'webp',
      );

      final path = fmt.formatting('%(extractor)s/%(id)s/%(file)s.%(ext)s');
      expect(path, 'hentai/123456/001.webp');

      final titled = fmt.formatting('%(extractor)s/[%(id)s] %(title)s/%(file)s.%(ext)s');
      expect(titled, 'hentai/[123456] Test Title  With InvalidChars/001.webp');
    });

    test('restores QueryResult offline from Metadata JSON snapshot', () {
      final original = QueryResult(
        result: {
          'Id': 987654,
          'Title': 'Offline Ready Title',
          'Artists': '|artist_one|artist_two|',
          'Groups': '|circle_x|',
          'Tags': '|female:glasses|male:sole_male|',
          'Language': 'korean',
          'Files': 24,
        },
      );

      final item = DownloadItemModel(
        result: {
          'Id': 1,
          'State': 0,
          'URL': '987654',
          'Info': '[987654] Offline Ready Title',
          'Files': jsonEncode([
            '/tmp/hentai/987654/thumbnail.jpg',
            '/tmp/hentai/987654/000.webp',
            '/tmp/hentai/987654/001.webp',
          ]),
          'Metadata': jsonEncode(original.result),
        },
      );

      final restored = item.toQueryResult();
      expect(restored, isNotNull);
      expect(restored!.id(), 987654);
      expect(restored.title(), 'Offline Ready Title');
      expect(item.displayTitle(), 'Offline Ready Title');
      expect(item.displayArtist(), 'artist_one, artist_two');
      expect(item.filesWithoutThumbnail(), [
        '/tmp/hentai/987654/000.webp',
        '/tmp/hentai/987654/001.webp',
      ]);
    });

    test('autoTranslate setting defaults to false and toggles in test mode', () async {
      expect(Settings.autoTranslate.value, isFalse);
      await Settings.autoTranslate.setValue(true);
      expect(Settings.autoTranslate.value, isTrue);
      await Settings.autoTranslate.setValue(false);
      expect(Settings.autoTranslate.value, isFalse);
    });
  });
}
