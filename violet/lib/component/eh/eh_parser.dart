// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:intl/intl.dart';
import 'package:violet/log/log.dart';
import 'package:violet/src/rust/api/html_parser.dart' as rust_html;
import 'package:violet/src/rust/frb_generated.dart';

class EHArticle {
  late String thumbnail;
  late String title;
  late String subTitle;
  late String type;
  late String uploader;

  // Left side of article info
  late String posted;
  late String parent;
  late String visible;
  late String language;
  late String fileSize;
  late int length;
  late int favorited;
  late int imagesPerPage;

  // Right side of article info
  String? reclass;
  List<String>? languages;
  List<String>? group;
  List<String>? parody;
  List<String>? character;
  List<String>? artist;
  List<String>? male;
  List<String>? female;
  List<String>? misc;

  List<(DateTime, String, String)>? comment;
  List<String>? imageLink;
}

class EHResultArticle {
  String? url;

  String? thumbnail;
  String? title;

  String? uploader;
  String? published;
  String? files;
  String? type;

  Map<String, List<String>>? descripts;
}

// E-Hentai, EX-Hentai Parser
// You can use both of the previous.
class EHParser {
  static bool get _useRust {
    try {
      return RustLib.instance.initialized;
    } catch (_) {
      return false;
    }
  }

  static EHResultArticle _fromRustResultArticle(
    rust_html.EhResultArticleParsed r,
  ) {
    final article = EHResultArticle()
      ..url = r.url
      ..thumbnail = r.thumbnail
      ..title = r.title
      ..uploader = r.uploader
      ..published = r.published
      ..files = r.files
      ..type = r.articleType;
    if (r.descriptKeys.isNotEmpty) {
      final dict = <String, List<String>>{};
      for (var i = 0; i < r.descriptKeys.length; i++) {
        dict[r.descriptKeys[i]] = r.descriptValues[i];
      }
      article.descripts = dict;
    }
    return article;
  }

  static EHArticle _fromRustArticle(rust_html.EhArticleParsed p) {
    final article = EHArticle()
      ..thumbnail = p.thumbnail
      ..imagesPerPage = p.imagesPerPage
      ..title = p.title
      ..subTitle = p.subTitle
      ..posted = p.posted
      ..parent = p.parent
      ..visible = p.visible
      ..language = p.language
      ..fileSize = p.fileSize
      ..length = p.length
      ..favorited = p.favorited
      ..languages = p.languages
      ..group = p.group
      ..parody = p.parody
      ..character = p.character
      ..artist = p.artist
      ..male = p.male
      ..female = p.female
      ..misc = p.misc;
    if (p.uploader != null) article.uploader = p.uploader!;

    final df = DateFormat('dd MMMM yyyy, H:m');
    final comments = <(DateTime, String, String)>[];
    for (final c in p.comments) {
      final date = c.postedRaw;
      comments.add((
        df.parse(
          date
              .substring(
                0,
                date.contains(' by') ? date.indexOf(' by') : date.length,
              )
              .substring('Posted on '.length),
          true,
        ),
        c.author,
        c.contents,
      ));
    }
    comments.sort((x, y) => x.$1.compareTo(y.$1));
    article.comment = comments;
    return article;
  }

  static final RegExp _thumbnailPattern = RegExp(
    r'https://(s\.)?(exhentai|ehgt).org/.*?(?=\))',
  );

  static bool validHtml(String html) {
    final removed = html.contains(
      'This gallery has been removed or is unavailable.',
    );
    return !removed;
  }

  // ex: https://exhentai.org/g/1212168/421ef300a8/
  static List<String> getImagesUrl(String html) {
    if (_useRust) {
      return rust_html.parseEhImagesUrlSync(html: html);
    }
    var doc = parse(html).querySelector("div[id='gdt']");
    var result = <String>[];
    doc!.querySelectorAll('div').forEach((element) {
      var a = element.querySelector('a');
      if (a == null) return;
      var url = element.querySelector('a')!.attributes['href'];
      if (!result.contains(url)) result.add(url!);
    });
    doc.querySelectorAll('a').forEach((element) {
      var url = element.attributes['href'];
      if (!result.contains(url)) result.add(url!);
    });
    return result;
  }

  // ex: https://exhentai.org/g/1212168/421ef300a8/?inline_set=ts_l
  static List<String> getThumbnailImages(String html) {
    final RegExp regex = RegExp(
      r'\"(https://e[-x]hentai.org/t/.*?|https://ehgt.org/.{2}/.{2}/.*?)\"',
    );
    return regex.allMatches(html).map((e) => e.group(1)!).toList();
  }

  // ex: https://exhentai.org/s/df24b19548/1212549-2
  static String getImageAddress(String html) {
    if (_useRust) {
      return rust_html.parseEhImageAddressSync(html: html);
    }
    var doc = parse(html).querySelector("div[id='i1']");
    return doc!.querySelector("div[id='i3'] a img")!.attributes['src']!;
  }

  // ex: https://exhentai.org/s/df24b19548/1212549-2
  static String getOriginalImageAddress(String html) {
    final RegExp regex = RegExp(
      r'\<a href="(https://e[-x]hentai.org/fullimg\.php.*?)"\>',
    );
    return regex.allMatches(html).first.group(1)!;
  }

  static EHArticle parseArticleData(String html) {
    if (_useRust) {
      return _fromRustArticle(rust_html.parseEhArticleDataSync(html: html));
    }
    var article = EHArticle();
    var h = parse(html);
    var doc = h.querySelector('div.gm');

    try {
      article.thumbnail = _thumbnailPattern
          .stringMatch(
            doc!.querySelector('div[id=gleft] div div')!.attributes['style']!,
          )
          .toString();
    } catch (e) {
      rethrow;
    }

    final imagesPerPageRegex = RegExp(r'(\d+)\s*-\s*(\d+)\s*of\s*(\d+)');

    final imagesPerPageMatch = imagesPerPageRegex.firstMatch(
      parse(html).querySelector('[class="gtb"] > [class="gpc"]')!.text,
    );
    int firstIndex = imagesPerPageMatch!.group(1) != null
        ? int.parse(imagesPerPageMatch.group(1)!) - 1
        : 0;
    int lastIndex = imagesPerPageMatch.group(2) != null
        ? int.parse(imagesPerPageMatch.group(2)!)
        : 0;

    article.imagesPerPage = lastIndex - firstIndex;

    article.title = doc.querySelector("div[id='gd2'] h1[id='gn']")!.text;
    article.subTitle = doc.querySelector("div[id='gd2'] h1[id='gj']")!.text;

    var tryUploader = doc.querySelector("div[id='gmid'] div[id='gdn']");
    if (tryUploader != null) article.uploader = tryUploader.text;

    var nodeStatic = doc.querySelectorAll(
      "div[id='gmid'] div[id='gdd'] table tr",
    );

    article.posted = nodeStatic[0].querySelector("td[class='gdt2']")!.text;
    article.parent = nodeStatic[1].querySelector("td[class='gdt2']")!.text;
    article.visible = nodeStatic[2].querySelector("td[class='gdt2']")!.text;
    article.language = nodeStatic[3].querySelector("td[class='gdt2']")!.text;
    article.fileSize = nodeStatic[4].querySelector("td[class='gdt2']")!.text;
    article.length = int.parse(
      nodeStatic[5]
          .querySelector("td[class='gdt2']")!
          .text
          .replaceAll('pages', '')
          .trim(),
    );
    article.favorited = int.parse(
      nodeStatic[6]
          .querySelector("td[class='gdt2']")!
          .text
          .replaceAll('times', '')
          .replaceAll('Once', '1')
          .trim(),
    );

    var nodesData = doc.querySelectorAll(
      "div[id='gmid'] div[id='taglist'] table tr",
    );
    var info = <String, List<String>>{};

    for (var element in nodesData) {
      try {
        info[element.querySelector('td')!.text.trim()] = element
            .querySelectorAll('td')[1]
            .querySelectorAll('div')
            .map((x) => x.querySelector('a')!.text)
            .toList();
      } catch (e, st) {
        Logger.error(
          '[eh-parser] E: $e\n'
          '$st',
        );
      }
    }

    if (info.containsKey('language:')) article.languages = info['language:'];
    if (info.containsKey('group:')) article.group = info['group:'];
    if (info.containsKey('parody:')) article.parody = info['parody:'];
    if (info.containsKey('character:')) article.character = info['character:'];
    if (info.containsKey('artist:')) article.artist = info['artist:'];
    if (info.containsKey('male:')) article.male = info['male:'];
    if (info.containsKey('female:')) article.female = info['female:'];
    if (info.containsKey('misc:')) article.misc = info['misc:'];

    var nodeComments = h.querySelectorAll("div[id='cdiv'] > div.c1");
    var comments = <(DateTime, String, String)>[];

    var hu = HtmlUnescape();
    var df = DateFormat('dd MMMM yyyy, H:m');
    for (var element in nodeComments) {
      var date = hu.convert(
        element.querySelector('div.c2 div.c3')!.text.trim(),
      );
      var author = hu.convert(
        (element.querySelector('div.c2 div.c3 > a')?.text ??
                ((element.querySelector('div.c4.nosel')?.text ?? '').trim() ==
                        'Uploader Comment'
                    ? article.uploader
                    : ''))
            .trim(),
      );
      var contents = hu.convert(
        element.querySelector('div.c6')!.innerHtml.replaceAll('<br>', '\r\n'),
      );
      comments.add((
        df.parse(
          date
              .substring(
                0,
                date.contains(' by') ? date.indexOf(' by') : date.length,
              )
              .substring('Posted on '.length),
          true,
        ),
        author,
        contents,
      ));
    }

    comments.sort((x, y) => x.$1.compareTo(y.$1));
    article.comment = comments;

    return article;
  }

  // ex: https://exhentai.org/?inline_set=dm_t
  static List<EHResultArticle> parseReulstPageThumbnailView(String html) {
    if (_useRust) {
      return rust_html
          .parseEhThumbnailViewSync(html: html)
          .map(_fromRustResultArticle)
          .toList();
    }
    var result = <EHResultArticle>[];

    var nodes = parse(html).querySelectorAll('div.itg > div.id1');

    for (var element in nodes) {
      try {
        var article = EHResultArticle();

        article.url = element.querySelector('div.id2 a')!.attributes['href'];

        try {
          article.thumbnail = element
              .querySelector('div.id3 a img')!
              .attributes['src'];
        } catch (_) {}
        article.title = element.querySelector('div.id2 a')!.text;

        article.files = element.querySelector('div.id42')!.text;
        article.type = element.querySelector('div.id41')!.attributes['title'];

        result.add(article);
      } catch (_) {}
    }

    return result;
  }

  // ex: https://exhentai.org/?inline_set=dm_l
  static List<EHResultArticle> parseReulstPageListView(String html) {
    if (_useRust) {
      return rust_html
          .parseEhListViewSync(html: html)
          .map(_fromRustResultArticle)
          .toList();
    }
    var result = <EHResultArticle>[];

    var nodes = parse(html).querySelectorAll('div.itg > tr');

    if (nodes.length > 1) nodes.removeAt(0);

    for (var element in nodes) {
      try {
        var article = EHResultArticle();
        var tds = element.querySelectorAll('td');

        article.url = tds[2].querySelector('div.it5 a')!.attributes['href'];

        try {
          article.thumbnail = tds[2]
              .querySelector('div.it2 img')!
              .attributes['src'];
        } catch (_) {}
        article.title = tds[2].querySelector('div.it5 a')!.text;

        article.uploader = tds[3].querySelector('div > a')!.attributes['href'];
        article.published = tds[1].text;
        article.type = tds[0].querySelector('a img')!.attributes['alt'];

        result.add(article);
      } catch (_) {}
    }

    return result;
  }

  // ex: https://exhentai.org/?inline_set=dm_e
  // The html source is broken. Therefore, you have to do fucking like this.
  static List<EHResultArticle> parseReulstPageExtendedListView(String html) {
    if (_useRust) {
      return rust_html
          .parseEhExtendedListViewSync(html: html)
          .map(_fromRustResultArticle)
          .toList();
    }
    var result = <EHResultArticle>[];

    var q = <Element>[];
    parse(
      html,
    ).querySelectorAll('table.itg.glte').forEach((element) => q.add(element));

    while (q.isNotEmpty) {
      var node = q[0];
      q.removeAt(0);

      try {
        var article = EHResultArticle();

        article.url = node.querySelector('a')!.attributes['href'];
        try {
          article.thumbnail = node.querySelector('img')!.attributes['src'];
        } catch (_) {}

        var g13 = node.querySelectorAll('td')[1].querySelector('div > div');
        var g13div = g13!.querySelectorAll('div');

        article.type = g13div[0].text.toLowerCase();
        article.published = g13div[1].text;
        article.uploader = g13div[3].text;
        article.files = g13div[4].text;

        var gref = node
            .querySelectorAll('td')[1]
            .querySelector('div > a > div');

        article.title = gref!.querySelector('div')!.text;

        try {
          var dict = <String, List<String>>{};

          gref.querySelector('div > table')!.querySelectorAll('tr').forEach((
            element,
          ) {
            var cont = element.querySelector('td')!.text.trim();
            cont = cont.substring(0, cont.length - 1);

            var cc = <String>[];

            element
                .querySelectorAll('td')[1]
                .querySelectorAll('div')
                .forEach((element) => cc.add(element.text));

            dict[cont] = cc;
          });
          article.descripts = dict;
        } catch (e) {
          print(e);
        }

        // Do not add already contained article
        if (!result.any((e) => e.url == article.url)) {
          result.add(article);
        }

        var next = node.querySelectorAll('tr');

        q.addAll(next);
      } catch (_) {}
    }

    return result;
  }

  static Future<List<EHResultArticle>> parseReulstPageExtendedListViewAsync(
    String html,
  ) async {
    if (_useRust) {
      final rows = await rust_html.parseEhExtendedListView(html: html);
      return rows.map(_fromRustResultArticle).toList();
    }
    return parseReulstPageExtendedListView(html);
  }

  // ex: https://exhentai.org/?inline_set=dm_m
  static List<EHResultArticle> parseReulstPageMinimalListView(String html) {
    if (_useRust) {
      return rust_html
          .parseEhMinimalListViewSync(html: html)
          .map(_fromRustResultArticle)
          .toList();
    }
    var result = <EHResultArticle>[];

    var nodes = parse(html).querySelectorAll("table[class='itg gltm'] > tr");

    if (nodes.length > 1) nodes.removeAt(0);

    for (var element in nodes) {
      var article = EHResultArticle();

      article.type = element
          .querySelector('td > div')!
          .text
          .trim()
          .toLowerCase();
      article.thumbnail = element.querySelector('img')!.attributes['src'];
      if (article.thumbnail!.startsWith('data')) {
        article.thumbnail = element
            .querySelector('img')!
            .attributes['data-src'];
      }
      article.published = element
          .querySelectorAll('td')[1]
          .querySelectorAll('div')[1]
          .querySelectorAll('div')[1]
          .querySelectorAll('div')[0]
          .querySelectorAll('div')[1]
          .text
          .trim();
      article.files = element
          .querySelectorAll('td')[1]
          .querySelectorAll('div')[1]
          .querySelectorAll('div')[1]
          .querySelectorAll('div')[1]
          .querySelectorAll('div')[1]
          .text
          .trim();

      article.url = element
          .querySelectorAll('td')[3]
          .querySelector('a')!
          .attributes['href'];
      article.title = element
          .querySelectorAll('td')[3]
          .querySelector('a  div')!
          .text
          .trim();
      article.uploader = element
          .querySelectorAll('td')[5]
          .querySelector('div a')!
          .text
          .trim();

      result.add(article);
    }

    return result;
  }
}
