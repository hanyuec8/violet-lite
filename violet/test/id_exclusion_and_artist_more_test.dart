// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:auto_animated/auto_animated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/image_provider.dart';
import 'package:violet/component/local_article_filter.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/bookmark.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/model/article_list_item.dart';
import 'package:violet/pages/artist_info/article_list_page.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/widgets/article_item/article_list_item_widget.dart';
import 'package:violet/widgets/article_item/image_provider_manager.dart';

class _FakeImageProvider extends VioletImageProvider {
  @override
  bool canGetImageUrlSync() => true;
  @override
  Future<double> getEstimatedImageHeight(int page, double baseWidth) async =>
      baseWidth * 1.4;
  @override
  Future<Map<String, String>> getHeader(int page) async => const {};
  @override
  Future<String> getImageUrl(int page) async => '';
  @override
  String? getImageUrlSync(int page) => '';
  @override
  Future<double> getOriginalImageHeight(int page) async => 1000;
  @override
  Future<List<String>> getSmallImagesUrl() async => const [];
  @override
  Future<String> getThumbnailUrl() async => '';
  @override
  Future<void> init() async {}
  @override
  bool isRefreshable() => false;
  @override
  int length() => 10;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshPartial(List<bool> target) async {}
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('violet_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => tempDir.path,
    );
    final user = await User.load().then((_) => User.getInstance());
    await user.getUserLog();
    await Bookmark.getInstance();
  });

  tearDownAll(() async {
    await CommonUserDatabase.reloadInstance();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  tearDown(() async {
    await Settings.excludeTags.setValue([]);
  });

  group('ID Exclusion (품번 제외) Tests', () {
    final qr2703806 = QueryResult(result: {
      'Id': 2703806,
      'Title': 'Korean Work 1',
      'Artists': '|erect sawaru|',
      'Tags': '|female:sole female|',
      'Language': 'korean',
    });
    final qr2840219 = QueryResult(result: {
      'Id': 2840219,
      'Title': 'Korean Work 2',
      'Artists': '|erect sawaru|',
      'Tags': '|female:sole female|',
      'Language': 'korean',
    });
    final qr2841896 = QueryResult(result: {
      'Id': 2841896,
      'Title': 'Korean Work 3',
      'Artists': '|erect sawaru|',
      'Tags': '|female:sole female|',
      'Language': 'korean',
    });

    test('Settings.isExcluded supports id:, bare numeric, range, and operators', () async {
      await Settings.excludeTags.setValue(['id:2703806']);
      expect(Settings.isExcluded(qr2703806), isTrue);
      expect(Settings.isExcluded(qr2840219), isFalse);
      // Direct ID query bypasses exclusion
      expect(Settings.isExcluded(qr2703806, currentQuery: '2703806'), isFalse);
      expect(Settings.isExcluded(qr2703806, currentQuery: 'id:2703806'), isFalse);
      // Artist query still applies ID exclusion
      expect(Settings.isExcluded(qr2703806, currentQuery: 'artist:erect_sawaru'), isTrue);

      await Settings.excludeTags.setValue(['2840219']);
      expect(Settings.isExcluded(qr2840219), isTrue);
      expect(Settings.isExcluded(qr2703806), isFalse);
      expect(Settings.isExcluded(qr2840219, currentQuery: 'id:2840219'), isFalse);

      await Settings.excludeTags.setValue(['-id:2841896']);
      expect(Settings.isExcluded(qr2841896), isTrue);
      expect(Settings.serializedExcludeTags, equals('-id:2841896'));

      await Settings.excludeTags.setValue(['id:2700000~2841000']);
      expect(Settings.isExcluded(qr2703806), isTrue);
      expect(Settings.isExcluded(qr2840219), isTrue);
      expect(Settings.isExcluded(qr2841896), isFalse);

      await Settings.excludeTags.setValue(['id:2703806,2841896']);
      expect(Settings.isExcluded(qr2703806), isTrue);
      expect(Settings.isExcluded(qr2840219), isFalse);
      expect(Settings.isExcluded(qr2841896), isTrue);
    });

    test('translate2query handles negative numeric IDs and id!= properly', () {
      final singleNeg = translate2query('-2703806', filter: false);
      expect(singleNeg, contains('Id != 2703806'));
      expect(singleNeg, isNot(contains('Id=-2703806')));

      final comboNegNum = translate2query('artist:erect_sawaru -2703806', filter: false);
      expect(comboNegNum, contains('Id != 2703806'));
      expect(comboNegNum, isNot(contains("Title NOT LIKE '%2703806%'")));

      final comboNegId = translate2query('artist:erect_sawaru -id:2703806', filter: false);
      expect(comboNegId, contains('Id != 2703806'));

      final comboNotEq = translate2query('artist:erect_sawaru id!=2703806', filter: false);
      expect(comboNotEq, contains('Id != 2703806'));

      final negRange = translate2query('-id:2700000~2841000', filter: false);
      expect(negRange, contains('(Id < 2700000 OR Id > 2841000)'));
    });

    test('HybridLoader.matchesAllQueryTokens filters -id: and negative numeric IDs', () {
      expect(
        HybridLoader.matchesAllQueryTokens(qr2703806, ['-id:2703806']),
        isFalse,
      );
      expect(
        HybridLoader.matchesAllQueryTokens(qr2840219, ['-id:2703806']),
        isTrue,
      );
      expect(
        HybridLoader.matchesAllQueryTokens(qr2703806, ['-2703806']),
        isFalse,
      );
      expect(
        HybridLoader.matchesAllQueryTokens(qr2840219, ['id!=2703806']),
        isTrue,
      );
      expect(
        HybridLoader.matchesAllQueryTokens(qr2703806, ['id!=2703806']),
        isFalse,
      );
      expect(
        HybridLoader.matchesAllQueryTokens(
          qr2841896,
          ['artist:erect_sawaru', '-id:2703806', '-2840219'],
        ),
        isTrue,
      );
      expect(
        HybridLoader.matchesAllQueryTokens(
          qr2840219,
          ['artist:erect_sawaru', '-id:2703806', '-2840219'],
        ),
        isFalse,
      );
    });

    test('HybridLoader.formatEHentaiQuery strips id/page/date tokens cleanly', () {
      expect(
        HybridLoader.formatEHentaiQuery('artist:erect_sawaru -id:2703806 -2840219', 'korean'),
        equals('language:korean artist:erect sawaru'),
      );
      expect(
        HybridLoader.formatEHentaiQuery('-id:2703806', 'korean'),
        equals('language:korean'),
      );
    });

    test('LocalArticleFilter supports id: and -id: filtering', () {
      final list = [qr2703806, qr2840219, qr2841896];
      expect(
        LocalArticleFilter.filter(list, '-id:2703806').map((e) => e.id()),
        equals([2840219, 2841896]),
      );
      expect(
        LocalArticleFilter.filter(list, '-2840219').map((e) => e.id()),
        equals([2703806, 2841896]),
      );
      expect(
        LocalArticleFilter.filter(list, 'id:2840219').map((e) => e.id()),
        equals([2840219]),
      );
      expect(
        LocalArticleFilter.filter(list, '-id:2700000~2841000').map((e) => e.id()),
        equals([2841896]),
      );
    });
  });

  group('Artist More (ArticleListPage) Completeness Tests', () {
    List<QueryResult> buildKorean71Articles() {
      final list = <QueryResult>[];
      final specialIds = [3355576, 3354406, 3281199, 2841896, 2840219, 2703806];
      for (final id in specialIds) {
        ProviderManager.insert(id, _FakeImageProvider());
        list.add(QueryResult(result: {
          'Id': id,
          'Title': 'Korean Work $id',
          'Artists': '|erect sawaru|',
          'Tags': '|female:sole female|',
          'Language': 'korean',
        }));
      }
      for (int i = 0; i < 65; i++) {
        final id = 2600000 - i * 100;
        ProviderManager.insert(id, _FakeImageProvider());
        list.add(QueryResult(result: {
          'Id': id,
          'Title': 'Older Korean Work $i',
          'Artists': '|erect sawaru|',
          'Tags': '|female:sole female|',
          'Language': 'korean',
        }));
      }
      return list;
    }

    testWidgets(
      'ArticleListPage keeps all 71 Korean works including 2703806, 2840219, 2841896 even when all-lang cache only has newer works',
      (WidgetTester tester) async {
        final korean71 = buildKorean71Articles();
        final all60OnlyNew = List<QueryResult>.generate(
          60,
          (i) => QueryResult(result: {
            'Id': 4200000 - i * 1000,
            'Title': 'New Japanese Work $i',
            'Artists': '|erect sawaru|',
            'Tags': '|female:sole female|',
            'Language': 'japanese',
          }),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArticleListPage(
                name: 'Artist: erect sawaru',
                cc: korean71,
                initialLanguage: 'korean',
                artistName: 'erect sawaru',
                artistType: ArtistType.artist,
                isWebMode: true,
                initialLangCache: {
                  'korean': korean71,
                  'all': all60OnlyNew,
                },
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));

        expect(find.text('Artist: erect sawaru (71)'), findsOneWidget);
        final grid = tester.widget<LiveSliverGrid>(find.byType(LiveSliverGrid));
        expect(grid.itemCount, equals(71));
        final firstGridIds = tester
            .elementList(find.byType(ArticleListItemWidget))
            .map((e) => Provider.of<ArticleListItem>(e, listen: false).queryResult.id())
            .toList();
        expect(firstGridIds, containsAll([2841896, 2840219, 2703806]));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets(
      'ArticleListPage applies Settings.excludeTags ID exclusion on displayed works and count',
      (WidgetTester tester) async {
        final korean71 = buildKorean71Articles();
        await Settings.excludeTags.setValue(['id:2703806', '2840219']);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArticleListPage(
                name: 'Artist: erect sawaru',
                cc: korean71,
                initialLanguage: 'korean',
                artistName: 'erect sawaru',
                artistType: ArtistType.artist,
                isWebMode: true,
                initialLangCache: {'korean': korean71},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));

        expect(find.text('Artist: erect sawaru (69)'), findsOneWidget);
        final grid = tester.widget<LiveSliverGrid>(find.byType(LiveSliverGrid));
        expect(grid.itemCount, equals(69));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  });
}
