// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:violet/component/downloadable.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/database/query.dart';
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
