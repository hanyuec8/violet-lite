// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:violet/component/hitomi/hitomi_nozomi.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/hitomi/message_corpus_manager.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/pages/search/message_search_view.dart';
import 'package:violet/pages/search/search_page.dart';
import 'package:violet/pages/search/search_page_controller.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/message_search.dart' as rust_msg;
import 'package:violet/src/rust/frb_generated.dart';

void main() {
  late Directory corpusDir;
  late File fscmFile;
  late bool rustReady;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();
    await Settings.enableMessageSearch.setValue(true);
    await Settings.enableHangulTypoRestore.setValue(true);
    await TagTranslate.init();

    final dllFile = File('rust/target/debug/rust_lib_violet.dll');
    rustReady = dllFile.existsSync();
    if (rustReady) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(dllFile.path),
      );

      corpusDir = await MessageCorpusManager.instance.getCorpusDir();
      fscmFile = File(p.join(corpusDir.path, 'filter_regression_test.fscm'));
      await rust_msg.buildFscmFile(
        outputPath: fscmFile.path,
        entries: [
          rust_msg.FscmBuildEntry(
            articleId: 3001,
            page: 1,
            text: '안녕하세요 엘프 대사입니다',
            storeRaw: true,
            correctness: 0.99,
            rect: Float32List.fromList([10, 20, 100, 120]),
          ),
          rust_msg.FscmBuildEntry(
            articleId: 3002,
            page: 2,
            text: '안녕하세요 일반 대사입니다',
            storeRaw: true,
            correctness: 0.98,
            rect: Float32List.fromList([15, 25, 110, 130]),
          ),
          rust_msg.FscmBuildEntry(
            articleId: 3003,
            page: 3,
            text: '안녕하세요 제외될 대사입니다',
            storeRaw: true,
            correctness: 0.97,
            rect: Float32List.fromList([20, 30, 120, 140]),
          ),
        ],
      );
      await MessageCorpusManager.instance.initIfEnabled();
    }
  });

  tearDownAll(() async {
    MessageCorpusManager.instance.testForceEmptyLocalDb = false;
    HitomiNozomi.testFetchAllOverride = null;
    HitomiNozomi.testTitleWordOverride = null;
    HitomiNozomi.clearCaches();
    if (rustReady) {
      rust_msg.mobileSearchUnload();
      if (await fscmFile.exists()) {
        await fscmFile.delete();
      }
      if (await corpusDir.exists() && corpusDir.listSync().isEmpty) {
        await corpusDir.delete();
      }
    }
  });

  setUp(() {
    MessageCorpusManager.instance.testForceEmptyLocalDb = true;
    HitomiNozomi.clearCaches();
    HitomiNozomi.testFetchAllOverride = (url) async {
      if (url.endsWith('/tag/female:elf-korean.nozomi')) {
        return [3001, 3003];
      }
      if (url.endsWith('/tag/female:dark%20skin-korean.nozomi')) {
        return [3002];
      }
      if (url.endsWith('/tag/female:netorare-korean.nozomi')) {
        return [3003];
      }
      if (url.endsWith('/artist/nishi-korean.nozomi')) {
        return [3001, 3002];
      }
      if (url.endsWith('/index-korean.nozomi')) {
        return [3001, 3002, 3003];
      }
      return const [];
    };
  });

  group('MessageCorpusManager.resolveArticleFilter', () {
    test('resolves single, multi-tag AND, OR, negation, and Korean/typo tags on empty DB', () async {
      final mgr = MessageCorpusManager.instance;

      final single = await mgr.resolveArticleFilter('female:elf');
      expect(single.whitelistIds, unorderedEquals([3001, 3003]));

      final andRes = await mgr.resolveArticleFilter('female:elf artist:nishi');
      expect(andRes.whitelistIds, equals([3001]));

      final negRes = await mgr.resolveArticleFilter('female:elf -female:netorare');
      expect(negRes.whitelistIds, equals([3001]));

      final negOnly = await mgr.resolveArticleFilter('-female:netorare');
      expect(negOnly.whitelistIds, unorderedEquals([3001, 3002]));

      final orRes = await mgr.resolveArticleFilter(
        '(female:elf or female:dark_skin) artist:nishi',
      );
      expect(orRes.whitelistIds, unorderedEquals([3001, 3002]));

      final korTag = await mgr.resolveArticleFilter('female:엘프');
      expect(korTag.whitelistIds, unorderedEquals([3001, 3003]));

      final typoTag = await mgr.resolveArticleFilter('dpfvm');
      expect(typoTag.whitelistIds, unorderedEquals([3001, 3003]));

      final idSingle = await mgr.resolveArticleFilter('3002');
      expect(idSingle.idMin, equals(3002));
      expect(idSingle.idMax, equals(3002));

      final mixedPost = await mgr.resolveArticleFilter('female:elf page>30');
      expect(mixedPost.whitelistIds, unorderedEquals([3001, 3003]));
      expect(mixedPost.postFilterCondition, equals('page>30'));

      final pageOnly = await mgr.resolveArticleFilter('page>30');
      expect(pageOnly.errorMessage, isNotNull);
    });

    test('merges local DB matches with Hitomi Nozomi when local DB is populated', () async {
      final mgr = MessageCorpusManager.instance;
      mgr.testForceEmptyLocalDb = false;

      final merged = await mgr.resolveArticleFilter('female:elf');
      expect(merged.whitelistIds, containsAll([3001, 3003]));
      expect(merged.whitelistIds!.length, greaterThan(2));
    });
  });

  group('MessageSearchView filter autocomplete and filtered search', () {
    testWidgets('shows prefix and tag autocomplete chips and inserts selected tags', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MessageSearchView(),
        ),
      );
      await tester.pumpAndSettle();

      final conditionField = find.byType(TextField).last;
      await tester.tap(conditionField);
      await tester.pump();

      expect(find.text('필터 접두사 선택'), findsOneWidget);
      final femalePrefixChip = find.text('female: (여성 태그)');
      expect(femalePrefixChip, findsOneWidget);

      await tester.tap(femalePrefixChip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<TextField>(conditionField).controller!.text,
        equals('female:'),
      );

      await tester.enterText(conditionField, 'female:elf');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      final elfChip = find.text('female:elf · 엘프');
      expect(elfChip, findsOneWidget);

      await tester.tap(elfChip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<TextField>(conditionField).controller!.text,
        equals('female:elf '),
      );

      // 영타 오타(dpfvm -> 엘프) 및 부정(-) 접두사 보존 검증
      await tester.enterText(conditionField, '-dpfvm');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(find.text('제외(-)'), findsOneWidget);
      final negElfChip = find.text('-female:elf · 엘프');
      expect(negElfChip, findsOneWidget);

      await tester.tap(negElfChip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<TextField>(conditionField).controller!.text,
        equals('-female:elf '),
      );
    });

    testWidgets('filters dialogue search results using condition tag', (
      WidgetTester tester,
    ) async {
      if (!rustReady) {
        markTestSkipped('rust_lib_violet.dll not built in debug target');
        return;
      }

      await tester.pumpWidget(
        const MaterialApp(
          home: MessageSearchView(),
        ),
      );
      await tester.pumpAndSettle();

      final dialogueField = find.byType(TextField).first;
      final conditionField = find.byType(TextField).last;

      await tester.enterText(dialogueField, '안녕하세요');
      await tester.enterText(conditionField, 'female:elf -female:netorare');
      await tester.pump();

      await tester.tap(find.text('검색'));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('안녕하세요 엘프 대사입니다').evaluate().isNotEmpty) {
          break;
        }
      }

      expect(find.text('안녕하세요 엘프 대사입니다'), findsOneWidget);
      expect(find.text('안녕하세요 일반 대사입니다'), findsNothing);
      expect(find.text('안녕하세요 제외될 대사입니다'), findsNothing);
    });

    testWidgets('SearchPage searchBar does not overlap query text with action icons on mobile width', (
      WidgetTester tester,
    ) async {
      if (!rustReady) {
        markTestSkipped('rust_lib_violet.dll not built in debug target');
        return;
      }

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: SearchPage(skipInitialSearch: true),
        ),
      );
      await tester.pump();
      SearchPageController.current?.latestQuery = (null, '3705471');
      SearchPageController.current?.reloadForce();
      await tester.pump(const Duration(milliseconds: 100));

      final queryText = find.text('3705471');
      final closeIcon = find.byIcon(Icons.close);
      final dialogueIcon = find.byIcon(MdiIcons.commentSearchOutline);
      final starIcon = find.byIcon(MdiIcons.starOutline);

      expect(queryText, findsOneWidget);
      expect(closeIcon, findsOneWidget);
      expect(dialogueIcon, findsOneWidget);
      expect(starIcon, findsOneWidget);

      final queryRect = tester.getRect(queryText.first);
      final closeRect = tester.getRect(closeIcon.first);
      final dialogueRect = tester.getRect(dialogueIcon.first);
      final starRect = tester.getRect(starIcon.first);

      expect(queryRect.right, lessThanOrEqualTo(closeRect.left));
      expect(closeRect.right, lessThanOrEqualTo(dialogueRect.left));
      expect(dialogueRect.right, lessThanOrEqualTo(starRect.left));
    });

    test('HitomiNozomi B-Tree decoder and multi-word title search finds 4329253', () async {
      // 1) B-Tree 바이너리 노드 디코딩 검증
      final keyBytes = HitomiNozomi.hashSearchTerm('boku');
      final bb = BytesBuilder();
      final hdr = ByteData(8);
      hdr.setInt32(0, 1, Endian.big); // 1 key
      hdr.setInt32(4, 4, Endian.big); // key size 4
      bb.add(hdr.buffer.asUint8List());
      bb.add(keyBytes);
      final dataHdr = ByteData(16);
      dataHdr.setInt32(0, 1, Endian.big); // 1 data
      dataHdr.setUint64(4, 123456, Endian.big);
      dataHdr.setInt32(12, 80, Endian.big);
      bb.add(dataHdr.buffer.asUint8List());
      final subs = ByteData(17 * 8);
      bb.add(subs.buffer.asUint8List());

      final decoded = HitomiNozomi.decodeBTreeNode(bb.toBytes());
      expect(decoded, isNotNull);
      expect(decoded!.keys.length, equals(1));
      expect(decoded.keys.first, equals(keyBytes));
      expect(decoded.datas.first, equals((123456, 80)));
      expect(decoded.isLeaf, isTrue);

      // 2) HybridLoader.fetchGalleryIdsForQuery('boku dake') 제목 교집합 검색 검증
      HitomiNozomi.testTitleWordOverride = (term) async {
        if (term == 'boku') return [4330000, 4329253, 4100000];
        if (term == 'dake') return [4329253, 3900000];
        return const [];
      };
      HitomiNozomi.testFetchAllOverride = (url) async {
        if (url.endsWith('/index-korean.nozomi')) {
          return [4330000, 4329253, 3900000];
        }
        return const [];
      };
      addTearDown(() {
        HitomiNozomi.testTitleWordOverride = null;
      });

      final ids = await HybridLoader.fetchGalleryIdsForQuery(
        query: 'boku dake',
        page: 1,
        pageSize: 30,
        targetLang: 'korean',
      );
      expect(ids, equals([4329253]));
    });

    test('MessageCorpusManager.isReady stays true after engine mounted across redundant initIfEnabled', () async {
      if (!rustReady) {
        markTestSkipped('rust_lib_violet.dll not built in debug target');
        return;
      }
      final mgr = MessageCorpusManager.instance;
      expect(mgr.isReady, isTrue);
      await mgr.initIfEnabled();
      expect(mgr.isReady, isTrue);
    });
  });
}
