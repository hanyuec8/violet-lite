// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/component/local_article_filter.dart';
import 'package:violet/database/query.dart';
import 'package:violet/pages/segment/filter_page_controller.dart';

void main() {
  setUpAll(() async {
    await TagTranslate.init();
  });

  final sampleBookmarks = <QueryResult>[
    QueryResult(result: {
      'Id': 101,
      'Title': 'Short Elf Story',
      'Artists': '|nishi|',
      'Tags': '|female:elf|female:sole female|',
      'Language': 'korean',
      'Type': 'doujinshi',
      'Files': 24,
    }),
    QueryResult(result: {
      'Id': 102,
      'Title': 'Medium Anthology',
      'Artists': '|alpha|',
      'Tags': '|full color|',
      'Language': 'korean',
      'Type': 'manga',
      'Files': 60,
    }),
    QueryResult(result: {
      'Id': 103,
      'Title': 'Long Tankoubon',
      'Artists': '|nishi|',
      'Tags': '|female:elf|',
      'Language': 'korean',
      'Type': 'manga',
      'Files': 180,
    }),
    QueryResult(result: {
      'Id': 104,
      'Title': 'Unknown Pages Work',
      'Artists': '|beta|',
      'Tags': '|female:elf|',
      'Language': 'korean',
      'Files': null,
    }),
  ];

  group('Bookmark Page Count & Local Search Filter', () {
    test('supports >, >=, <, <=, =, ==, range, and negation operators', () {
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page>100')
            .map((e) => e.id()),
        equals([103]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page>=60')
            .map((e) => e.id()),
        equals([102, 103]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page<60')
            .map((e) => e.id()),
        equals([101]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page<=60')
            .map((e) => e.id()),
        equals([101, 102]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page=24')
            .map((e) => e.id()),
        equals([101]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page==60')
            .map((e) => e.id()),
        equals([102]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, 'page:25~190')
            .map((e) => e.id()),
        equals([102, 103]),
      );
      expect(
        LocalArticleFilter.filter(sampleBookmarks, '-page>50')
            .map((e) => e.id()),
        equals([101]),
      );
    });

    test('combines FilterController min/max pages, tag chips, and Korean typo', () {
      final controller = FilterController()
        ..tagStates = {'female|elf': true}
        ..minPages = 100;

      final filtered = controller.applyFilter(sampleBookmarks);
      expect(filtered.map((e) => e.id()), equals([103]));

      final controller2 = FilterController()
        ..localQuery = 'ㄹ드미ㄷ:dpfvm ㅔㅁㅎㄷ<=30';
      expect(
        controller2.applyFilter(sampleBookmarks).map((e) => e.id()),
        equals([101]),
      );
    });

    test('supports simultaneous include and exclude tags (A included, B excluded)', () {
      final controller = FilterController();
      controller.setTagState('female|elf', TagFilterState.include);
      controller.setTagState('female|sole female', TagFilterState.exclude);

      final filtered = controller.applyFilter(sampleBookmarks);
      expect(filtered.map((e) => e.id()), equals([103, 104]));
    });

    test('exclude takes precedence even when isOr is enabled', () {
      final controller = FilterController()..isOr = true;
      controller.setTagState('female|elf', TagFilterState.include);
      controller.setTagState('tag|full color', TagFilterState.include);
      controller.setTagState('artist|nishi', TagFilterState.exclude);

      // 101 and 103 match female:elf but have artist nishi -> excluded
      // 102 matches full color, 104 matches female:elf (beta) -> kept
      final filtered = controller.applyFilter(sampleBookmarks);
      expect(filtered.map((e) => e.id()), equals([102, 104]));
    });

    test('cycleTagState and toggleExcludeTag transition cleanly and resetAll clears', () {
      final controller = FilterController();
      expect(controller.getTagState('female|elf'), TagFilterState.none);
      expect(controller.cycleTagState('female|elf'), TagFilterState.include);
      expect(controller.includedTagKeys, equals(['female|elf']));
      expect(controller.cycleTagState('female|elf'), TagFilterState.exclude);
      expect(controller.includedTagKeys, isEmpty);
      expect(controller.excludedTagKeys, equals(['female|elf']));
      expect(controller.cycleTagState('female|elf'), TagFilterState.none);
      expect(controller.hasAnyActiveFilter, isFalse);

      expect(controller.toggleExcludeTag('male|shota'), TagFilterState.exclude);
      expect(controller.activeFilterCount, equals(1));
      controller.resetAll();
      expect(controller.hasAnyActiveFilter, isFalse);
    });
  });
}
