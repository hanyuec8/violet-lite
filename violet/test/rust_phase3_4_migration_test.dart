// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/eh/eh_parser.dart';
import 'package:violet/component/hitomi/hitomi_parser.dart';
import 'package:violet/component/hitomi/hybrid_loader.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/component/hitomi/title_cluster.dart';
import 'package:violet/component/index.dart';
import 'package:violet/component/local_article_filter.dart';
import 'package:violet/database/query.dart';
import 'package:violet/src/rust/api/tag_index_store.dart' as rust_tag_store;
import 'package:violet/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async {
    if (Platform.isWindows) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          'rust/target/debug/rust_lib_violet.dll',
        ),
      );
    }
    await TagTranslate.init();
  });

  group('Phase 3.1: Rust HTML Parser parity', () {
    test('HitomiParser.parseGalleryBlock parses via Rust FFI', () async {
      const html = '''
<div class="dj">
<a href="/doujinshi/sample-4185588.html"><img data-src="//tn.gold-usergeneratedcontent.net/webpbigtn/2/20/sample.webp"></a>
<h1>Sample Work</h1>
<div class="artist-list"><ul><li><a href="/artist/nishi-all.html">nishi</a></li></ul></div>
<div class="dj-content">
<table class="dj-desc">
<tr><td>Series</td><td class="series-list"><a href="/series/s.html">Sample Series</a></td></tr>
<tr><td>Type</td><td><a href="/type/doujinshi-all.html">doujinshi</a></td></tr>
<tr><td>Language</td><td><a href="/index-korean.html">한국어</a></td></tr>
<tr><td>Tags</td><td class="relatedtags"><ul>
<li><a href="/tag/female%3Aamputee-all.html">amputee ♀</a></li>
<li><a href="/tag/male%3Aamputee-all.html">amputee ♂</a></li>
<li><a href="/tag/digital-all.html">digital</a></li>
</ul></td></tr>
</table>
</div>
</div>
''';
      final parsed = await HitomiParser.parseGalleryBlock(html);
      expect(parsed['Title'], 'Sample Work');
      expect(parsed['Thumbnail'], 'webpbigtn/2/20/sample.webp');
      expect(parsed['Artists'], ['nishi']);
      expect(parsed['Series'], ['Sample Series']);
      expect(parsed['Type'], 'doujinshi');
      expect(parsed['Language'], 'korean');
      expect(parsed['Tags'], ['female:amputee', 'male:amputee', 'digital']);
    });

    test('EHParser extended list view parses via Rust FFI', () async {
      const html = '''
<table class="itg glte">
  <tr>
    <td><a href="https://exhentai.org/g/12345/abcdef1234/"><img src="https://ehgt.org/t/1.jpg"></a></td>
    <td>
      <div>
        <div><div>Doujinshi</div><div>2026-01-01 12:00</div><div></div><div>upuser</div><div>24 pages</div></div>
        <a href="https://exhentai.org/g/12345/abcdef1234/"><div>
          <div>Sample EH Title</div>
          <div><table>
            <tr><td>female:</td><td><div>sole female</div></td></tr>
            <tr><td>language:</td><td><div>korean</div><div>translated</div></td></tr>
          </table></div>
        </div></a>
      </div>
    </td>
  </tr>
</table>
''';
      final syncRes = EHParser.parseReulstPageExtendedListView(html);
      final asyncRes = await EHParser.parseReulstPageExtendedListViewAsync(html);
      expect(syncRes.length, 1);
      expect(asyncRes.length, 1);
      expect(syncRes.first.title, 'Sample EH Title');
      expect(asyncRes.first.descripts?['female'], ['sole female']);
      expect(asyncRes.first.uploader, 'upuser');
    });
  });

  group('Phase 3.2: Rust LocalArticleFilter batch parity', () {
    test('matches Dart filter output across page, id, and Korean translated tags', () {
      final items = List.generate(30, (i) {
        return QueryResult(result: {
          'Id': 1000 + i,
          'Title': i % 2 == 0 ? 'Elf Story $i' : 'Other Work $i',
          'Artists': i % 3 == 0 ? '|nishi|' : '|alpha|',
          'Tags': i % 2 == 0 ? '|female:elf|female:sole female|' : '|full color|',
          'Language': 'korean',
          'Type': 'doujinshi',
          'Files': 20 + i * 5,
        });
      });

      for (final query in [
        'page>=100',
        '-id:1000~1010',
        'female:엘프',
        'artist:nishi -page>120',
        '단독여성',
      ]) {
        final tokens = LocalArticleFilter.parseQuery(query);
        final rustOut = LocalArticleFilter.filterViaRust(items, tokens);
        final dartOut = items
            .where((a) => tokens.every((t) => LocalArticleFilter.matchesToken(a, t)))
            .toList();
        expect(
          rustOut.map((e) => e.id()).toList(),
          equals(dartOut.map((e) => e.id()).toList()),
          reason: 'mismatch for query=$query',
        );
      }
    });
  });

  group('Phase 4.1: Rust Title Clustering & Matching', () {
    test('HitomiTitleCluster & HybridLoader.isTitleMatched run via Rust', () async {
      final titles = List.generate(
        25,
        (i) => i < 3 ? 'Winter Story Vol.${i + 1}' : 'Unique Title #$i (${i * 17})',
      );
      final syncClusters = HitomiTitleCluster.doClustering(titles);
      final asyncClusters = await HitomiTitleCluster.doClusteringAsync(titles);
      expect(syncClusters.first, equals([0, 1, 2]));
      expect(asyncClusters.first, equals([0, 1, 2]));

      expect(
        HybridLoader.isTitleMatched(
          'Usugoori no Kanojo-tachi | 살얼음의 그녀들 (decensored)',
          '[Dendoro Kakariya] Usugoori no Kanojo-tachi [English]',
        ),
        isTrue,
      );
    });
  });

  group('Phase 4.2: Rust TagIndexStore', () {
    test('HentaiIndex loads test/db into Rust store without Dart relation maps', () async {
      HentaiIndex.tagCount = null;
      HentaiIndex.tagArtist = {};
      await HentaiIndex.init();

      expect(rust_tag_store.tagIndexIsLoaded(), isTrue);
      expect(HentaiIndex.tagCount, isNull);
      expect(HentaiIndex.tagArtist, isEmpty);

      final ac = await HentaiIndex.queryAutoComplete('fema');
      expect(ac.first.$1.toString(), 'female:females only');
      expect(ac.any((e) => e.$1.toString() == 'female:sole female'), isTrue);

      final fuzzy = await HentaiIndex.queryAutoCompleteFuzzy('michoking');
      expect(fuzzy.first.$1.toString(), 'artist:michiking');
    });
  });
}
