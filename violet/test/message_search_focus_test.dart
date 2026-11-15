// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/component/hitomi/message_corpus_manager.dart';
import 'package:violet/pages/search/message_search_view.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/message_search.dart' as rust_msg;
import 'package:violet/src/rust/frb_generated.dart';

void main() {
  late Directory corpusDir;
  late File fscmFile;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();
    await Settings.enableMessageSearch.setValue(true);

    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        'rust/target/debug/rust_lib_violet.dll',
      ),
    );

    corpusDir = await MessageCorpusManager.instance.getCorpusDir();
    fscmFile = File(p.join(corpusDir.path, 'focus_regression_test.fscm'));
    await rust_msg.buildFscmFile(
      outputPath: fscmFile.path,
      entries: [
        rust_msg.FscmBuildEntry(
          articleId: 3001,
          page: 2,
          text: '안녕하세요 테스트 대사입니다',
          storeRaw: true,
          correctness: 0.99,
          rect: Float32List.fromList([10, 20, 100, 120]),
        ),
      ],
    );
    await MessageCorpusManager.instance.initIfEnabled();
  });

  tearDownAll(() async {
    rust_msg.mobileSearchUnload();
    if (await fscmFile.exists()) {
      await fscmFile.delete();
    }
    if (await corpusDir.exists() && corpusDir.listSync().isEmpty) {
      await corpusDir.delete();
    }
  });

  testWidgets(
    'does not restore focus to search TextField after dialog dismiss',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MessageSearchView(),
        ),
      );
      await tester.pumpAndSettle();

      final dialogueFieldFinder = find.byType(TextField).first;
      await tester.tap(dialogueFieldFinder);
      await tester.pump();

      final dialogueTextField = tester.widget<TextField>(dialogueFieldFinder);
      final dialogueFocusNode = dialogueTextField.focusNode!;
      expect(dialogueFocusNode.hasFocus, isTrue);

      await tester.enterText(dialogueFieldFinder, '안녕');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(dialogueFocusNode.hasFocus, isFalse);
      final routeScope = FocusScope.of(
        tester.element(dialogueFieldFinder),
      );
      expect(routeScope.focusedChild, isNull);

      // 다이얼로그 열기 후 뒤로가기(닫기) 시뮬레이션
      final BuildContext ctx = tester.element(find.byType(MessageSearchView));
      showDialog<void>(
        context: ctx,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('미리보기'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();

      expect(dialogueFocusNode.hasFocus, isFalse);
      expect(routeScope.focusedChild, isNull);

      // 이후 사용자가 검색창을 다시 탭하면 정상적으로 포커스가 잡혀야 함
      await tester.tap(dialogueFieldFinder);
      await tester.pump();
      expect(dialogueFocusNode.hasFocus, isTrue);
    },
  );

  testWidgets(
    'switches between detail view and grid view and persists mode',
    (WidgetTester tester) async {
      await Settings.messageSearchGridMode.setValue(false);

      await tester.pumpWidget(
        const MaterialApp(
          home: MessageSearchView(),
        ),
      );
      await tester.pumpAndSettle();

      final dialogueFieldFinder = find.byType(TextField).first;
      await tester.enterText(dialogueFieldFinder, '안녕');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('안녕하세요 테스트 대사입니다').evaluate().isNotEmpty) {
          break;
        }
      }

      // 기본값은 디테일 뷰(ListView)
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(SliverGrid), findsNothing);
      expect(Settings.messageSearchGridMode.value, isFalse);

      // 그리드 뷰 전환 버튼 탭
      await tester.tap(find.byTooltip('그리드 뷰'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(Settings.messageSearchGridMode.value, isTrue);
      expect(find.text('안녕하세요 테스트 대사입니다'), findsOneWidget);

      // 다시 디테일 뷰 전환 버튼 탭
      await tester.tap(find.byTooltip('디테일 뷰'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(SliverGrid), findsNothing);
      expect(Settings.messageSearchGridMode.value, isFalse);
    },
  );
}
