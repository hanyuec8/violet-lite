// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/pages/article_info/preview_area.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/widgets/dots_indicator.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();
  });

  Widget buildPreviewPage(int pageIndex, {int itemCount = 30}) {
    return GridView.count(
      physics: const ScrollPhysics(),
      shrinkWrap: true,
      crossAxisCount: 3,
      childAspectRatio: 3 / 4,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      children: List.generate(
        itemCount,
        (i) => Container(
          color: Colors.blueGrey.shade200,
          alignment: Alignment.center,
          child: Text('P$pageIndex-$i'),
        ),
      ),
    );
  }

  testWidgets('does not overflow right when preview pages exceed 600p (>20 dots)', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 25 chunks * 30p = 750p (> 600p)
    final pages = List.generate(25, (i) => buildPreviewPage(i));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExpandablePageView(children: pages),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('P0-0'), findsOneWidget);
    expect(find.byType(DotsIndicator), findsOneWidget);
  });

  testWidgets('tapping dots navigates to the selected preview page', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final pages = List.generate(25, (i) => buildPreviewPage(i));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExpandablePageView(children: pages),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('P0-0'), findsOneWidget);

    // Tap dot 5 (index 5)
    final dotFinder = find.descendant(
      of: find.byType(DotsIndicator),
      matching: find.byType(InkResponse),
    );
    expect(dotFinder, findsNWidgets(25));

    await tester.tap(dotFinder.at(5));
    await tester.pumpAndSettle();

    expect(find.text('P5-0'), findsOneWidget);
    expect(find.text('P0-0'), findsNothing);

    // Dot bar auto-centered around index 5, so distant dot 12 is now visible and tappable
    await tester.ensureVisible(dotFinder.at(12));
    await tester.tap(dotFinder.at(12));
    await tester.pumpAndSettle();

    expect(find.text('P12-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swiping preview scrolls outer ListView back to preview top', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    final pages = List.generate(3, (i) => buildPreviewPage(i));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scrollController,
            children: [
              const SizedBox(height: 400, child: Text('Header Info')),
              ExpandablePageView(children: pages),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Scroll deep into the bottom of page 0
    scrollController.jumpTo(1100.0);
    await tester.pump();
    expect(scrollController.offset, 1100.0);

    // Swipe horizontally from right to left to go to page 1
    await tester.drag(find.byType(PageView), const Offset(-260, 0));
    await tester.pumpAndSettle();

    expect(find.text('P1-0'), findsOneWidget);
    // Should scroll back up to top of ExpandablePageView (~400.0), not stay at 1100.0
    expect(scrollController.offset, closeTo(400.0, 2.0));
  });

  testWidgets(
    'swiping preview inside DraggableScrollableSheet scrolls back to preview top',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final pages = [
        buildPreviewPage(0, itemCount: 30),
        buildPreviewPage(1, itemCount: 6),
      ];
      late ScrollController sheetController;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DraggableScrollableSheet(
              initialChildSize: 0.9,
              minChildSize: 0.5,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, controller) {
                sheetController = controller;
                return ListView(
                  controller: controller,
                  children: [
                    const SizedBox(height: 400, child: Text('Article Header')),
                    ExpandablePageView(children: pages),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll down into page 0
      sheetController.jumpTo(950.0);
      await tester.pump();
      expect(sheetController.offset, 950.0);

      // Swipe to shorter last page 1
      await tester.drag(find.byType(PageView), const Offset(-260, 0));
      await tester.pumpAndSettle();

      expect(find.text('P1-0'), findsOneWidget);
      // Either aligned at 400.0 or clamped to maxScrollExtent if page 1 is shorter
      expect(sheetController.offset, lessThanOrEqualTo(402.0));
      expect(tester.takeException(), isNull);
    },
  );
}
