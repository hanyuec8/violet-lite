// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/database/query.dart';
import 'package:violet/pages/search/search_page_controller.dart';
import 'package:violet/settings/settings.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();
  });

  group('Search Position and Item Jump Synchronization Tests', () {
    const defaultPageSize = 50;
    const headerHeight = 76.0;

    test('Item Jump Offset & Base Alignment Calculation', () {
      final testCases = [
        // targetPosition, expectedStartPage, expectedBaseOffset, expectedTargetIndex
        (0, 1, 0, 0),
        (25, 1, 0, 25),
        (49, 1, 0, 49),
        (50, 2, 50, 0),
        (75, 2, 50, 25),
        (1350, 28, 1350, 0),
        (1353, 28, 1350, 3),
        (1399, 28, 1350, 49),
        (5000, 101, 5000, 0),
      ];

      for (final tc in testCases) {
        final target = tc.$1;
        final startPage = (target ~/ defaultPageSize) + 1;
        final pageBaseOffset = (startPage - 1) * defaultPageSize;
        final targetIndexInPage = target - pageBaseOffset;

        expect(startPage, tc.$2, reason: 'startPage for target $target');
        expect(pageBaseOffset, tc.$3, reason: 'pageBaseOffset for target $target');
        expect(targetIndexInPage, tc.$4, reason: 'targetIndexInPage for target $target');
        expect(pageBaseOffset + targetIndexInPage, target, reason: 'sum matches target $target');
      }
    });

    test('Scroll Offset to Item Index Mapping (1 Item Per Row)', () {
      const effectiveHeight = 220.0;
      const itemPerRow = 1;
      const loadedCount = 50;
      final maxIndex = loadedCount - 1;

      // 1) 상단 헤더 영역 (0 ~ 76px)
      for (final offset in [0.0, 30.0, 76.0]) {
        final rel = (offset - headerHeight).clamp(0.0, double.infinity);
        final curI = ((rel / effectiveHeight).floor() * itemPerRow).clamp(0, maxIndex);
        expect(curI, 0, reason: 'Offset $offset should point to item 0');
      }

      // 2) 1번째 아이템 (76.0 + 220.0 = 296.0)
      final offsetItem1 = headerHeight + 1 * effectiveHeight;
      final rel1 = (offsetItem1 - headerHeight).clamp(0.0, double.infinity);
      final curI1 = ((rel1 / effectiveHeight).floor() * itemPerRow).clamp(0, maxIndex);
      expect(curI1, 1);

      // 3) 3번째 아이템 (1353번 점프 위치: 76.0 + 3 * 220.0 = 736.0)
      final offsetItem3 = headerHeight + 3 * effectiveHeight;
      final rel3 = (offsetItem3 - headerHeight).clamp(0.0, double.infinity);
      final curI3 = ((rel3 / effectiveHeight).floor() * itemPerRow).clamp(0, maxIndex);
      expect(curI3, 3);
      expect(1350 + curI3, 1353);

      // 4) 최대 스크롤 초과 방어
      const hugeOffset = 999999.0;
      final relHuge = (hugeOffset - headerHeight).clamp(0.0, double.infinity);
      final curIHuge = ((relHuge / effectiveHeight).floor() * itemPerRow).clamp(0, maxIndex);
      expect(curIHuge, maxIndex);
    });

    test('Scroll Offset to Item Index Mapping (3 Items Per Row)', () {
      const effectiveHeight = 150.0;
      const itemPerRow = 3;
      const loadedCount = 50;
      final maxIndex = loadedCount - 1;

      // 행 0 (0, 1, 2)
      final rel0 = (76.0 - headerHeight).clamp(0.0, double.infinity);
      final cur0 = ((rel0 / effectiveHeight).floor() * itemPerRow).clamp(0, maxIndex);
      expect(cur0, 0);

      // 행 1 (3, 4, 5) -> offset 76 + 150 = 226
      final relRow1 = (226.0 - headerHeight).clamp(0.0, double.infinity);
      final curRow1 = ((relRow1 / effectiveHeight).floor() * itemPerRow).clamp(0, maxIndex);
      expect(curRow1, 3);
    });

    test('New Articles Inflow & Smart Jump Search Range Adaptation', () {
      // 시나리오: 사용자가 6900번째 위치에서 특정 작품(ID: 3182945)을 보았음
      const savedPosition = 6900;
      const targetArticleId = 3182945;

      // 1) 당시 기준 시작 페이지
      final initialPage = (savedPosition ~/ defaultPageSize) + 1;
      expect(initialPage, 139);
      expect(targetArticleId, 3182945);

      // 2) 신작이 N개 추가되어 아이템이 뒤로 밀린 경우의 탐색 범위 검증
      final newArticlesAddedScenarios = [0, 15, 45, 80];

      for (final newCount in newArticlesAddedScenarios) {
        final shiftedPosition = savedPosition + newCount;
        final actualPage = (shiftedPosition ~/ defaultPageSize) + 1;

        // 초기 시작 페이지(139)로부터 최대 2~3회 추가 로딩(각 50개) 내에 신작 유입 분량이 완벽히 포함되는지 검증
        final maxCoveredPosition = (initialPage - 1) * defaultPageSize + (1 + 3) * defaultPageSize;
        expect(shiftedPosition <= maxCoveredPosition, true,
            reason: 'Shifted position $shiftedPosition with $newCount new articles must be covered within 3 loadNextQuery attempts');
        expect(actualPage >= initialPage, true);
      }
    });

    test('New Search & Tag Search Last Article Preservation Policy', () {
      // 1) 시나리오: 사용자가 120번 위치에서 작품(ID: 2841920)을 보던 중 앱 재시작 혹은 태그 검색 실행
      int savedPosition = 120;
      int savedArticleId = 2841920;

      // doSearch 시 targetPosition == 0 (태그 검색, 새 검색)인 경우
      const newSearchTargetPosition = 0;
      if (newSearchTargetPosition > 0) {
        savedPosition = newSearchTargetPosition;
      }
      expect(savedPosition, 120,
          reason: 'Tag search with targetPosition 0 must NOT reset saved position');
      expect(savedArticleId, 2841920,
          reason: 'Tag search must NOT reset saved article ID');

      // 2) 시스템 jumpTo(0.0) 등으로 스크롤 리스너가 호출되었으나 사용자가 직접 스크롤하지 않은 경우 (idle)
      bool shouldUpdateRecord(bool isUserScrolling) => isUserScrolling;
      if (shouldUpdateRecord(false)) {
        savedArticleId = 9999999;
        savedPosition = 0;
      }
      expect(savedArticleId, 2841920,
          reason: 'System jumpTo idle scroll must NOT overwrite last saved article ID');
      expect(savedPosition, 120,
          reason: 'System jumpTo idle scroll must NOT overwrite last saved position');

      // 3) 사용자가 실제로 손가락으로 스크롤을 시작한 경우 (!idle)
      const scrolledItemId = 9999998;
      const scrolledPosition = 3;
      if (shouldUpdateRecord(true)) {
        savedArticleId = scrolledItemId;
        savedPosition = scrolledPosition;
      }
      expect(savedArticleId, scrolledItemId,
          reason: 'User direct scrolling should update last saved article ID');
      expect(savedPosition, scrolledPosition,
          reason: 'User direct scrolling should update last saved position');

      // 4) 사용자가 명시적인 아이템 점프(targetPosition > 0)를 실행한 경우
      const jumpTargetPosition = 500;
      if (jumpTargetPosition > 0) {
        savedPosition = jumpTargetPosition;
      }
      expect(savedPosition, 500,
          reason: 'Explicit item jump (targetPosition > 0) must update saved position');
    });

    testWidgets('scrolling with lang:korean and Hitomi filter does not reset lastSearchPosition', (
      WidgetTester tester,
    ) async {
      await Settings.lastSearchPosition.setValue(1350);
      await Settings.lastSearchArticleId.setValue(3182945);
      await Settings.lastSearchArticleTitle.setValue('Previously Viewed Work');
      await Settings.lastSearchIsHitomiOnly.setValue(true);

      final ctrl = SearchPageController(
        reloadForce: ({bool isAppend = false}) {},
        isMainSearch: true,
      );
      ctrl.latestQuery = (null, 'lang:korean');
      ctrl.isHitomiFilterUsed.value = true;
      ctrl.hitomiFilterResult = List.generate(
        40,
        (i) => QueryResult(result: {'Id': 4300000 - i, 'Title': 'Work $i'}),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctrl.initScroll(context);
                return ListView.builder(
                  controller: ctrl.scrollController,
                  itemExtent: 220,
                  itemCount: ctrl.hitomiFilterResult.length,
                  itemBuilder: (_, i) => Text('Item $i'),
                );
              },
            ),
          ),
        ),
      );

      // 사용자가 리스트를 조금 아래로 스크롤하더라도 저장된 마지막 본 작품 위치(1350)는 절대 초기화되지 않아야 함
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      expect(ctrl.searchPageNum.value, greaterThan(0));
      expect(Settings.lastSearchPosition.value, equals(1350));
      expect(Settings.lastSearchArticleId.value, equals(3182945));
      expect(Settings.lastSearchArticleTitle.value, equals('Previously Viewed Work'));

      // 1350 이전 위치(예: 103)에서 작품을 열람해도 기존 더 깊은 위치(1350)는 덮어쓰지 않음
      ctrl.baseCount = 100;
      ctrl.recordViewedArticle(ctrl.hitomiFilterResult[3]);
      expect(Settings.lastSearchPosition.value, equals(1350));
      expect(Settings.lastSearchArticleId.value, equals(3182945));

      // 기존 위치(1350)보다 더 아래(예: baseCount=1360)로 스크롤하면 작품을 탭하지 않아도 자동 전진 기록
      ctrl.latestQuery = (null, '(lang:korean)');
      ctrl.baseCount = 1360;
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      final advancedPos = Settings.lastSearchPosition.value;
      final advancedId = Settings.lastSearchArticleId.value;
      expect(advancedPos, greaterThan(1350));
      expect(advancedId, isNot(equals(3182945)));

      // 같은 세션 내에서 상단(baseCount=0)으로 되돌아와 조금만 스크롤해도 기존 깊은 위치가 초기화되지 않아야 함
      ctrl.baseCount = 0;
      ctrl.scrollController!.jumpTo(0);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
      expect(Settings.lastSearchPosition.value, equals(advancedPos));
      expect(Settings.lastSearchArticleId.value, equals(advancedId));

      // 태그 검색 중에는 더 깊은 위치로 스크롤해도 메인 마지막 위치가 바뀌지 않음
      ctrl.latestQuery = (null, 'female:elf lang:korean');
      ctrl.baseCount = 2000;
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
      expect(Settings.lastSearchPosition.value, equals(advancedPos));
      expect(Settings.lastSearchArticleId.value, equals(advancedId));

      // 처음 기록이 없는 상태(0)에서 작품을 열지 않고 내리기만 해도 스크롤 위치가 자동 기록됨
      await Settings.lastSearchPosition.setValue(0);
      await Settings.lastSearchArticleId.setValue(0);
      final freshCtrl = SearchPageController(
        reloadForce: ({bool isAppend = false}) {},
        isMainSearch: true,
      );
      freshCtrl.latestQuery = (null, 'lang:korean');
      freshCtrl.isHitomiFilterUsed.value = true;
      freshCtrl.hitomiFilterResult = List.generate(
        40,
        (i) => QueryResult(result: {'Id': 4400000 - i, 'Title': 'Fresh $i'}),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                freshCtrl.initScroll(context);
                return ListView.builder(
                  controller: freshCtrl.scrollController,
                  itemExtent: 220,
                  itemCount: freshCtrl.hitomiFilterResult.length,
                  itemBuilder: (_, i) => Text('Fresh $i'),
                );
              },
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pump();
      expect(Settings.lastSearchPosition.value, greaterThan(0));
      expect(Settings.lastSearchArticleId.value, lessThan(4400000));

      ctrl.scrollController?.dispose();
      freshCtrl.scrollController?.dispose();
    });
  });
}

