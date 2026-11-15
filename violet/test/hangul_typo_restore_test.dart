// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/hangul_auto_restorer.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/component/index.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async {
    if (Platform.isWindows &&
        File('rust/target/debug/rust_lib_violet.dll').existsSync()) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          'rust/target/debug/rust_lib_violet.dll',
        ),
      );
    }
    await TagTranslate.init();
    await HentaiIndex.loadCountMapIfRequired();
  });

  group('HangulAutoRestorer & Search Integration', () {
    test('restores two-set keyboard text and complex compound finals', () {
      const samples = [
        '안녕하세요',
        '값이',
        '읽고',
        '읽어',
        '앉아',
        '없다',
        '괜찮아',
        '빛나는',
        '단독여성',
      ];
      for (final s in samples) {
        final key = HangulAutoRestorer.disassembleLossless(s);
        expect(HangulAutoRestorer.keyboardToHangul(key), equals(s));
      }
    });

    test('distinguishes genuine Korean typos from valid English tags', () {
      expect(HangulAutoRestorer.tryRestoreKoreanWord('dpfvm'), equals('엘프'));
      expect(
        HangulAutoRestorer.tryRestoreKoreanWord('eksehrdutjd'),
        equals('단독여성'),
      );
      expect(HangulAutoRestorer.tryRestoreKoreanWord('sole_female'), isNull);
      expect(HangulAutoRestorer.tryRestoreKoreanWord('loli'), isNull);
      expect(HangulAutoRestorer.tryRestoreKoreanWord('shota'), isNull);
    });

    test('restores Korean-typed prefixes and page/date expressions', () {
      final t1 = HangulAutoRestorer.analyzeToken('ㄹ드미ㄷ:dpfvm');
      expect(t1.normalizedPrefix, equals('female'));
      expect(t1.restoredHangul, equals('엘프'));
      expect(t1.restoredExpression, equals('female:dpfvm'));

      expect(
        HangulAutoRestorer.normalizeQuery('ㄹ드미ㄷ:sole_female ㅔㅁㅎㄷ>=100'),
        equals('female:sole_female page>=100'),
      );

      final sql = translate2query('ㅔㅁㅎㄷ>=50 dkssud');
      expect(sql, contains('Files >= 50'));
      expect(sql, contains("Title LIKE '%안녕%'"));
    });

    test('autocomplete matches Korean typo in prefix and tag name', () async {
      final results = await HentaiIndex.queryAutoComplete('ㄹ드미ㄷ:eksehrdutjd');
      expect(
        results.any((r) => r.$1.group == 'female' && r.$1.name == 'sole female'),
        isTrue,
      );
    });
  });
}
