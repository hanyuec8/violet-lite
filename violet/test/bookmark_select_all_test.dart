// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:violet/component/image_provider.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/bookmark.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/model/article_list_item.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/widgets/article_item/article_list_item_widget.dart';
import 'package:violet/widgets/article_item/image_provider_manager.dart';

class _StubImageProvider extends VioletImageProvider {
  @override
  bool canGetImageUrlSync() => true;
  @override
  Future<double> getEstimatedImageHeight(int page, double baseWidth) async =>
      100;
  @override
  Future<Map<String, String>> getHeader(int page) async => const {};
  @override
  Future<String> getImageUrl(int page) async => '';
  @override
  String? getImageUrlSync(int page) => '';
  @override
  Future<double> getOriginalImageHeight(int page) async => 100;
  @override
  Future<List<String>> getSmallImagesUrl() async => const [];
  @override
  Future<String> getThumbnailUrl() async => '';
  @override
  Future<void> init() async {}
  @override
  bool isRefreshable() => false;
  @override
  int length() => 1;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshPartial(List<bool> target) async {}
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    tempDir = await Directory.systemTemp.createTemp('violet_bm_sel_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => tempDir.path,
    );
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();
    await Bookmark.load();
    await User.load();
    await (await Bookmark.getInstance()).getArticle();
    await (await User.getInstance()).getUserLog();
    for (final id in [1001, 1002, 1003]) {
      ProviderManager.insert(id, _StubImageProvider());
    }
  });

  tearDownAll(() async {
    ProviderManager.clear();
    try {
      final userDb = await CommonUserDatabase.getInstance();
      await userDb.db?.close();
    } catch (_) {}
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  testWidgets('select all updates yellow amber border on all ArticleListItemWidget items', (
    WidgetTester tester,
  ) async {
    final items = [
      QueryResult(result: {'Id': 1001, 'Title': 'A', 'Artists': 'x', 'Tags': ''}),
      QueryResult(result: {'Id': 1002, 'Title': 'B', 'Artists': 'y', 'Tags': ''}),
      QueryResult(result: {'Id': 1003, 'Title': 'C', 'Artists': 'z', 'Tags': ''}),
    ];

    var isCheckMode = true;
    final checked = <int>[1001];

    late StateSetter hostSetState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              hostSetState = setState;
              return SingleChildScrollView(
                child: Column(
                  children: items.map((qr) {
                    return Provider<ArticleListItem>.value(
                      key: ValueKey('item_${qr.id()}'),
                      value: ArticleListItem.fromArticleListItem(
                        queryResult: qr,
                        showDetail: true,
                        showUltra: false,
                        addBottomPadding: false,
                        width: 300,
                        thumbnailTag: 'thumb_${qr.id()}',
                        bookmarkMode: true,
                        bookmarkCallback: (_) {},
                        bookmarkCheckCallback: (_, _) {},
                        usableTabList: items,
                      ),
                      child: ArticleListItemWidget(
                        isCheckMode: isCheckMode,
                        isChecked: checked.contains(qr.id()),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    List<Color?> getItemBorderColors() {
      return find
          .byType(ArticleListItemWidget)
          .evaluate()
          .map((elem) {
            final container = find
                .descendant(
                  of: find.byWidget(elem.widget),
                  matching: find.byType(Container),
                )
                .evaluate()
                .first
                .widget as Container;
            return container.color;
          })
          .toList();
    }

    // 초기: 길게 누른 첫 번째 작품만 노란 테두리(Colors.amber)
    expect(
      getItemBorderColors(),
      equals([Colors.amber, Colors.transparent, Colors.transparent]),
    );

    // 전체 선택: 모든 작품 ID를 checked에 추가 후 rebuild
    hostSetState(() {
      for (final item in items) {
        if (!checked.contains(item.id())) {
          checked.add(item.id());
        }
      }
    });
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      getItemBorderColors(),
      equals([Colors.amber, Colors.amber, Colors.amber]),
    );

    // 선택 해제: 체크 모드 종료 시 모든 테두리 초기화
    hostSetState(() {
      checked.clear();
      isCheckMode = false;
    });
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      getItemBorderColors(),
      equals([Colors.transparent, Colors.transparent, Colors.transparent]),
    );
  });
}
