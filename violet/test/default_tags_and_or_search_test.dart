import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/query_boolean_parser.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/query.dart';
import 'package:violet/pages/search/search_page_controller.dart';
import 'package:violet/settings/settings.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Settings.prefs = await SharedPreferences.getInstance();
  });

  setUp(() async {
    await Settings.includeTags.setValue('(lang:korean)');
    await Settings.defaultTags.setValue('');
    await Settings.excludeTags.setValue([]);
  });

  group('Settings.defaultTags & composeQueryWithDefaultTags', () {
    test('remains independent from language setting Settings.includeTags', () async {
      await Settings.defaultTags.setValue('female:females_only');
      expect(Settings.includeTags.value, equals('(lang:korean)'));
      expect(Settings.normalizedDefaultTags, equals('female:females_only'));
    });

    test('applies default tags on initial empty query and combines with user query safely', () async {
      await Settings.defaultTags.setValue(
        'female:females_only or female:sole_female',
      );

      expect(
        Settings.composeQueryWithDefaultTags(''),
        equals('female:females_only or female:sole_female'),
      );

      expect(
        Settings.composeQueryWithDefaultTags('artist:foo'),
        equals('(female:females_only or female:sole_female) (artist:foo)'),
      );

      expect(
        Settings.composeQueryWithDefaultTags('random:1.25'),
        equals('(female:females_only or female:sole_female) random:1.25'),
      );

      expect(
        Settings.composeQueryWithDefaultTags('artist:foo order:week'),
        equals('(female:females_only or female:sole_female) (artist:foo) order:week'),
      );
    });

    test('bypasses default tags for single numeric ID queries or when disabled', () async {
      await Settings.defaultTags.setValue('female:females_only');

      expect(Settings.composeQueryWithDefaultTags('123456'), equals('123456'));
      expect(
        Settings.composeQueryWithDefaultTags('id:123456'),
        equals('id:123456'),
      );
      expect(
        Settings.composeQueryWithDefaultTags('artist:foo', applyDefaultTags: false),
        equals('artist:foo'),
      );
    });
  });

  group('QueryBooleanParser AST & Evaluation', () {
    final femalesOnlyWork = QueryResult(result: {
      'Id': 1,
      'Title': 'Females Only',
      'Tags': '|female:females_only|female:schoolgirl|',
      'Artists': '|artist_a|',
      'Language': 'korean',
    });

    final soleFemaleWork = QueryResult(result: {
      'Id': 2,
      'Title': 'Sole Female',
      'Tags': '|female:sole_female|',
      'Artists': '|artist_b|',
      'Language': 'english',
    });

    final yaoiFemaleWork = QueryResult(result: {
      'Id': 3,
      'Title': 'Mixed Tag',
      'Tags': '|female:females_only|male:yaoi|',
      'Artists': '|artist_a|',
      'Language': 'korean',
    });

    final otherWork = QueryResult(result: {
      'Id': 4,
      'Title': 'Other',
      'Tags': '|female:big_breasts|',
      'Artists': '|artist_a|',
      'Language': 'japanese',
    });

    test('evaluates OR query accurately', () {
      final ast = QueryBooleanParser.parse(
        'female:females_only or female:sole_female',
      )!;
      expect(QueryBooleanParser.matchesQueryNode(femalesOnlyWork, ast), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(soleFemaleWork, ast), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(yaoiFemaleWork, ast), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(otherWork, ast), isFalse);
    });

    test('gives AND tighter precedence than OR and respects parentheses', () {
      final astNoParen = QueryBooleanParser.parse(
        'female:females_only artist:artist_a or female:sole_female',
      )!;
      expect(QueryBooleanParser.matchesQueryNode(femalesOnlyWork, astNoParen), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(soleFemaleWork, astNoParen), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(otherWork, astNoParen), isFalse);

      final astParen = QueryBooleanParser.parse(
        '(female:females_only or female:sole_female) -male:yaoi',
      )!;
      expect(QueryBooleanParser.matchesQueryNode(femalesOnlyWork, astParen), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(soleFemaleWork, astParen), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(yaoiFemaleWork, astParen), isFalse);
      expect(QueryBooleanParser.matchesQueryNode(otherWork, astParen), isFalse);
    });

    test('evaluates language OR query accurately', () {
      final ast = QueryBooleanParser.parse('lang:korean or lang:english')!;
      expect(QueryBooleanParser.matchesQueryNode(femalesOnlyWork, ast), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(soleFemaleWork, ast), isTrue);
      expect(QueryBooleanParser.matchesQueryNode(otherWork, ast), isFalse);
    });

    test('expands DNF branches for E-Hentai queries', () {
      final queries = HybridLoader.buildEHentaiQueries(
        '(female:females_only or female:sole_female) (artist:foo)',
        'korean',
      );
      expect(
        queries,
        equals([
          'language:korean female:females only artist:foo',
          'language:korean female:sole female artist:foo',
        ]),
      );
    });

    test('translate2query preserves OR and parenthesized default tags in SQL', () {
      final sql = translate2query(
        '(female:females_only or female:sole_female) (artist:foo)',
        filter: false,
      );
      expect(sql, contains('OR'));
      expect(sql, contains('AND'));
      expect(sql, contains('female:females only'));
      expect(sql, contains('female:sole female'));
      expect(sql, contains('foo'));
    });
  });

  group('SearchPageController last-viewed guard with defaultTags', () {
    test('disables last-viewed recording when defaultTags is active', () async {
      final controller = SearchPageController(
        reloadForce: ({bool isAppend = false}) {},
        isMainSearch: true,
      );
      controller.isHitomiFilterUsed.value = true;
      controller.latestQuery = (null, '');

      expect(controller.canRecordLastViewedArticle, isTrue);

      await Settings.defaultTags.setValue('female:females_only');
      expect(controller.canRecordLastViewedArticle, isFalse);
    });
  });
}
