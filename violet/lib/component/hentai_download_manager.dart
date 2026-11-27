// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/component/downloadable.dart';
import 'package:violet/component/eh/eh_headers.dart';
import 'package:violet/component/eh/eh_parser.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/component/hitomi/hitomi_parser.dart';
import 'package:violet/database/query.dart';
import 'package:violet/network/wrapper.dart' as http;
import 'package:violet/script/script_manager.dart';
import 'package:violet/settings/settings.dart';

class OnlineDownloadExtraction {
  final QueryResult queryResult;
  final List<DownloadTask> tasks;
  final DownloadTask? thumbnailTask;

  OnlineDownloadExtraction({
    required this.queryResult,
    required this.tasks,
    this.thumbnailTask,
  });
}

class HentaiDonwloadManager {
  factory HentaiDonwloadManager.instance() => HentaiDonwloadManager();

  late RegExp urlMatcher;

  HentaiDonwloadManager() {
    urlMatcher = RegExp(r'^\d+$');
  }

  bool acceptURL(String url) {
    return urlMatcher.stringMatch(url) == url;
  }

  String defaultFormat() {
    return Settings.downloadRule.value;
  }

  String fav() {
    return 'https://ltn.gold-usergeneratedcontent.net/favicon-192x192.png';
  }

  bool loginRequire() => false;
  bool logined() => false;
  String name() => 'hentai';

  Future<void> setSession(String id, String pwd) async {}
  Future<bool> tryLogin() async => true;

  /// 입력된 작품 번호가 온라인(Hitomi / E-Hentai / ExHentai)에 실제 존재하는지 병렬로 빠르게 검증합니다.
  Future<QueryResult?> verifyOnlineArticle(String rawId) async {
    final cleanId = rawId.trim();
    final id = int.tryParse(cleanId);
    if (id == null || id <= 0) return null;

    final checks = <Future<QueryResult?>>[
      _verifyHitomiFast(id),
      _verifyEhentaiFast(id, onExh: false),
    ];

    try {
      final prefs = await SharedPreferences.getInstance();
      final cookie = prefs.getString('eh_cookies') ?? '';
      if (cookie.contains('igneous=')) {
        checks.add(_verifyEhentaiFast(id, onExh: true));
      }
    } catch (_) {}

    return _firstNonNull(checks);
  }

  Future<QueryResult?> _verifyHitomiFast(int id) async {
    try {
      final headers = await ScriptManager.runHitomiGetHeaderContent(
        id.toString(),
      );
      final res = await http
          .get(
            'https://ltn.gold-usergeneratedcontent.net/galleryblock/$id.html',
            headers: headers,
          )
          .timeout(const Duration(seconds: 4));

      if (res.statusCode != 200 || res.body.trim().isEmpty) return null;

      final article = await HitomiParser.parseGalleryBlock(res.body);
      final title = article['Title']?.toString().trim() ?? '';
      if (title.isEmpty) return null;

      String? encodePipe(dynamic list) {
        if (list is! Iterable) return null;
        final items = list
            .whereType<String>()
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        return items.isEmpty ? null : '|${items.join('|')}|';
      }

      return QueryResult(
        result: {
          'Id': id,
          'Title': title,
          'Artists': encodePipe(article['Artists']),
          'Series': encodePipe(article['Series']),
          'Tags': encodePipe(article['Tags']),
          'Type': article['Type'],
          'Language': article['Language'],
          'Published': article['Published'],
          'Thumbnail': article['Thumbnail'],
          'ExistOnHitomi': 1,
        },
      );
    } catch (_) {
      return null;
    }
  }

  Future<QueryResult?> _verifyEhentaiFast(int id, {required bool onExh}) async {
    try {
      final host = onExh ? 'exhentai.org' : 'e-hentai.org';
      final listHtml = await EHSession.requestString(
        'https://$host/?next=${id + 1}&f_sh=on',
      ).timeout(const Duration(seconds: 4));

      final href = html_parser
          .parse(listHtml)
          .querySelector('a[href*="/g/$id/"]')
          ?.attributes['href'];
      final ehash = href
          ?.split('/')
          .where((e) => e.isNotEmpty)
          .lastOrNull;
      if (ehash == null || ehash.isEmpty) return null;

      final html = await EHSession.requestString(
        'https://$host/g/$id/$ehash/?p=0&inline_set=ts_m',
      ).timeout(const Duration(seconds: 4));

      final articleEh = EHParser.parseArticleData(html);
      final title = articleEh.title.trim();
      if (title.isEmpty) return null;

      return QueryResult(
        result: {
          'Id': id,
          'EHash': ehash,
          'Title': title,
          'Artists': articleEh.artist?.join('|') ?? 'N/A',
        },
      );
    } catch (_) {
      return null;
    }
  }

  Future<QueryResult?> _firstNonNull(List<Future<QueryResult?>> futures) {
    final completer = Completer<QueryResult?>();
    var remaining = futures.length;
    if (remaining == 0) {
      completer.complete(null);
      return completer.future;
    }

    for (final future in futures) {
      future.then(
        (value) {
          if (value != null && !completer.isCompleted) {
            completer.complete(value);
            return;
          }
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        },
        onError: (_) {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        },
      );
    }
    return completer.future;
  }

  /// 완전 온라인 환경에 맞춰 웹에서 직접 작품 메타데이터를 조회합니다.
  Future<QueryResult?> resolveOnlineQueryResult(String rawId) async {
    final cleanId = rawId.trim();
    try {
      return await HentaiManager.idQueryWeb(cleanId);
    } catch (_) {
      final search = await HentaiManager.idSearch(cleanId);
      if (search.results.isNotEmpty) {
        return search.results.first;
      }
      return null;
    }
  }

  Future<OnlineDownloadExtraction?> createOnlineExtraction(
    String url,
    GeneralDownloadProgress gdp, {
    QueryResult? existingQueryResult,
  }) async {
    final target = existingQueryResult ?? await resolveOnlineQueryResult(url);
    if (target == null) return null;
    return await createOnlineExtractionFromQueryResult(target, gdp);
  }

  Future<List<DownloadTask>?> createTask(
    String url,
    GeneralDownloadProgress gdp,
  ) async {
    final extraction = await createOnlineExtraction(url, gdp);
    return extraction?.tasks;
  }

  Future<List<DownloadTask>?> createTaskFromQueryResult(
    QueryResult target,
    GeneralDownloadProgress gdp,
  ) async {
    final extraction = await createOnlineExtractionFromQueryResult(target, gdp);
    return extraction?.tasks;
  }

  Future<OnlineDownloadExtraction?> createOnlineExtractionFromQueryResult(
    QueryResult target,
    GeneralDownloadProgress gdp,
  ) async {
    gdp.simpleInfoCallback('[${target.id()}] ${target.title()}');

    await ScriptManager.refresh();

    final provider = await HentaiManager.getImageProvider(target);
    await provider.init();

    final thumbnailUrl = await provider.getThumbnailUrl();
    final thumbnailHeader = await provider.getHeader(0);
    gdp.thumbnailCallback(thumbnailUrl, jsonEncode(thumbnailHeader));

    final artist = _firstNonEmptyPipe(target.artists()) ??
        _firstNonEmptyPipe(target.groups());
    final group = _firstNonEmptyPipe(target.groups());
    final nowStr = DateTime.now().toString();
    final uploadStr = target.getDateTime()?.toString() ?? '';
    final pageCount = provider.length();

    // 메타데이터의 Files 필드가 비어 있으면 실제 페이지 수로 보강
    if (target.files() == null || target.files() == 0) {
      target.result['Files'] = pageCount;
    }

    DownloadTask? thumbnailTask;
    if (thumbnailUrl.isNotEmpty) {
      final thumbExt = _extensionFromImageUrl(thumbnailUrl);
      thumbnailTask = DownloadTask(
        url: thumbnailUrl,
        headers: thumbnailHeader,
        format: FileNameFormat(
          title: target.title()?.toString(),
          id: target.id().toString(),
          laugage: target.language()?.toString(),
          uploadDate: uploadStr,
          filenameWithoutExtension: 'thumbnail',
          artist: artist,
          group: group,
          extension: thumbExt.isEmpty ? 'jpg' : thumbExt,
          extractor: 'hentai',
          downloadDate: nowStr,
          className: target.classname()?.toString(),
          length: pageCount.toString(),
        ),
      );
    }

    final result = <DownloadTask>[];
    for (int i = 0; i < pageCount; i++) {
      final page = await provider.getImageUrl(i);
      final header = await provider.getHeader(i);
      final ext = _extensionFromImageUrl(page);

      result.add(
        DownloadTask(
          url: page,
          headers: header,
          format: FileNameFormat(
            title: target.title()?.toString(),
            id: target.id().toString(),
            laugage: target.language()?.toString(),
            uploadDate: uploadStr,
            filenameWithoutExtension: intToString(i, pad: 3),
            artist: artist,
            group: group,
            extension: ext.isEmpty ? 'webp' : ext,
            extractor: 'hentai',
            downloadDate: nowStr,
            className: target.classname()?.toString(),
            length: pageCount.toString(),
          ),
        ),
      );

      gdp.progressCallback(i + 1, pageCount);
    }

    return OnlineDownloadExtraction(
      queryResult: target,
      tasks: result,
      thumbnailTask: thumbnailTask,
    );
  }

  static String? _firstNonEmptyPipe(dynamic raw) {
    if (raw == null) return null;
    final parts = raw.toString().split('|');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String intToString(int i, {int pad = 0}) {
    var str = i.toString();
    var paddingToAdd = pad - str.length;
    return (paddingToAdd > 0)
        ? "${List.filled(paddingToAdd, '0').join('')}$i"
        : str;
  }

  static String _extensionFromImageUrl(String url) {
    if (url.contains('fullimg.php')) return 'jpg';

    final uri = Uri.tryParse(url);
    final filename = uri == null
        ? url.split('/').last
        : path.basename(uri.path);
    return path.extension(filename).replaceFirst('.', '');
  }
}
