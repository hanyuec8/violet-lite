// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/log/log.dart';

class DownloadItemModel {
  Map<String, dynamic> result;
  DownloadItemModel({required this.result});

  int id() => result['Id'];

  // 0: Complete
  // 1: Pending
  // 2: Extracting
  // 3: Downloading
  // 4: Post Processing
  // 5: Fail
  // 6: Stop
  // 7: Error-Unknown
  // 8: Error-Not Support
  // 9: Error-Login
  // 10: Error
  // 11: Nothing to download
  int state() => result['State'];
  String? path() => result['Path']; // directory
  String? files() => result['Files']; // files path json
  String? info() => result['Info'];
  String? dateTime() => result['DateTime'];
  String? extractor() => result['Extractor'];
  String url() => result['URL'];
  String? errorMsg() => result['ErrorMsg'];
  String? thumbnail() => result['Thumbnail']; // remote URL or local path
  String? thumbnailHeader() => result['ThumbnailHeader'];
  String? metadataJson() => result['Metadata'];
  String? localThumbnail() => result['LocalThumbnail'];

  QueryResult? queryResult;
  bool download = false;

  /// 온라인 검색 시 저장해 둔 메타데이터 스냅샷으로 QueryResult를 복원합니다.
  QueryResult? toQueryResult() {
    if (queryResult != null) return queryResult;
    final raw = metadataJson();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          queryResult = QueryResult(result: Map<String, dynamic>.from(decoded));
          return queryResult;
        }
      } catch (_) {}
    }

    final articleId = int.tryParse(url());
    if (articleId != null) {
      final fallbackTitle = _extractTitleFromInfo() ?? '[$articleId]';
      return QueryResult(
        result: {
          'Id': articleId,
          'Title': fallbackTitle,
          'Artists': '',
          'Files': filesWithoutThumbnail().length,
        },
      );
    }
    return null;
  }

  String? _extractTitleFromInfo() {
    final i = info();
    if (i == null || i.trim().isEmpty) return null;
    final stripped = i.replaceFirst(RegExp(r'^\[\d+\]\s*'), '').trim();
    return stripped.isEmpty ? i.trim() : stripped;
  }

  String displayTitle() {
    final qr = toQueryResult();
    final title = qr?.title()?.toString().trim() ?? '';
    if (title.isNotEmpty) return title;
    return _extractTitleFromInfo() ?? url();
  }

  String displayArtist() {
    final qr = toQueryResult();
    if (qr == null) return '';
    final artists = (qr.artists()?.toString() ?? '')
        .split('|')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (artists.isNotEmpty) return artists.join(', ');
    final groups = (qr.groups()?.toString() ?? '')
        .split('|')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return groups.join(', ');
  }

  void attachMetadata(QueryResult qr) {
    queryResult = qr;
    result['Metadata'] = jsonEncode(qr.result);
  }

  Future<void> update() async {
    var db = await CommonUserDatabase.getInstance();
    await db.update('DownloadItem', result, 'Id=?', [id()]);
  }

  Future<void> test() async {
    var db = await CommonUserDatabase.getInstance();
    await db.query('SELECT * FROM DownloadItem WHERE Id=${id()}');
  }

  Future<void> delete() async {
    var db = await CommonUserDatabase.getInstance();
    await db.delete('DownloadItem', 'Id=?', [id()]);
  }

  /// DB 레코드와 로컬에 저장된 실제 파일/폴더를 함께 삭제합니다.
  Future<void> deleteWithFiles() async {
    final filePaths = rawFiles();
    for (final filePath in filePaths) {
      try {
        final f = File(filePath);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    final thumb = localThumbnail();
    if (thumb != null && thumb.isNotEmpty) {
      try {
        final tf = File(thumb);
        if (await tf.exists()) {
          await tf.delete();
        }
      } catch (_) {}
    }

    final dirPath = path();
    if (dirPath != null && dirPath.isNotEmpty) {
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          final remaining = await dir.list().toList();
          if (remaining.isEmpty) {
            await dir.delete();
          }
        }
      } catch (_) {}
    }

    await delete();
  }

  /// 로컬에 저장된 파일 총 용량(bytes)을 계산합니다.
  Future<int> calculateDiskSizeBytes() async {
    int total = 0;
    final seen = <String>{};
    for (final filePath in rawFiles()) {
      if (!seen.add(filePath)) continue;
      try {
        final f = File(filePath);
        if (await f.exists()) {
          total += await f.length();
        }
      } catch (_) {}
    }
    final thumb = localThumbnail();
    if (thumb != null && thumb.isNotEmpty && seen.add(thumb)) {
      try {
        final f = File(thumb);
        if (await f.exists()) {
          total += await f.length();
        }
      } catch (_) {}
    }
    return total;
  }

  List<String> rawFiles() {
    if (files() == null || files() == '') return [];
    try {
      return (jsonDecode(files()!) as List<dynamic>)
          .map((e) => e as String)
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<String> filesWithoutThumbnail() {
    var rfiles = rawFiles();
    rfiles.removeWhere(
      (element) => p.basename(element).toLowerCase().startsWith('thumbnail'),
    );
    return rfiles;
  }

  String? tryThumbnailFile() {
    final explicitThumb = localThumbnail();
    if (explicitThumb != null && explicitThumb.isNotEmpty) {
      if (File(explicitThumb).existsSync()) {
        return explicitThumb;
      }
    }

    final rfiles = rawFiles();
    for (final element in rfiles) {
      if (p.basename(element).toLowerCase().startsWith('thumbnail') &&
          File(element).existsSync()) {
        return element;
      }
    }

    // 로컬 썸네일이 없다면 첫 번째 다운로드된 페이지를 썸네일로 사용
    for (final element in rfiles) {
      if (File(element).existsSync()) {
        return element;
      }
    }
    return null;
  }
}

class Download {
  static Download? _instance;
  static Lock lock = Lock();

  static Future<Download> getInstance() async {
    await lock.synchronized(() async {
      if (_instance == null) {
        final db = await CommonUserDatabase.getInstance();
        final rows = await db.query(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='DownloadItem';",
        );
        if (rows.isEmpty || rows[0].isEmpty) {
          try {
            await db.execute('''CREATE TABLE DownloadItem (
              Id integer primary key autoincrement,
              State integer,
              Path text,
              Files text,
              Info text,
              DateTime text,
              Extractor text,
              URL text,
              ErrorMsg text,
              Thumbnail text,
              ThumbnailHeader text,
              Metadata text,
              LocalThumbnail text
              );
              ''');
          } catch (e, st) {
            Logger.error(
              '[Download-Instance] E: $e\n'
              '$st',
            );
          }
        } else {
          // 기존 user.db에 DownloadItem 테이블이 있는 경우 신규 컬럼 안전 마이그레이션
          await _ensureColumns(db);
        }
        _instance = Download();
        await _instance!.init();
      }
    });
    return _instance!;
  }

  static Future<void> _ensureColumns(dynamic db) async {
    try {
      final info = await db.query('PRAGMA table_info(DownloadItem);');
      final existing = info
          .map<String>((row) => row['name']?.toString() ?? '')
          .toSet();
      if (!existing.contains('Metadata')) {
        await db.execute('ALTER TABLE DownloadItem ADD COLUMN Metadata text;');
      }
      if (!existing.contains('LocalThumbnail')) {
        await db.execute(
          'ALTER TABLE DownloadItem ADD COLUMN LocalThumbnail text;',
        );
      }
    } catch (e, st) {
      Logger.error('[Download-Migrate] E: $e\n$st');
    }
  }

  HashSet<int> _downloadedChecker = HashSet<int>();
  Map<int, DownloadItemModel> _downloadedItems = <int, DownloadItemModel>{};

  Future<void> init() async {
    var items = await getDownloadItems();
    for (var item in items) {
      int? no = int.tryParse(item.url());
      if (no != null && item.state() == 0) {
        _downloadedChecker.add(no);
        _downloadedItems[no] = item;
      }
    }
  }

  Future<void> refresh() async {
    _downloadedChecker = HashSet<int>();
    _downloadedItems = <int, DownloadItemModel>{};
    _isDownloadedFileExistsCache.clear();
    await init();
  }

  bool isDownloadedArticle(int id, bool checkFileExists) {
    if (!checkFileExists) {
      return _downloadedChecker.contains(id);
    }

    return _isDownloadedFileExists(id);
  }

  final Map<int, bool> _isDownloadedFileExistsCache = <int, bool>{};
  bool _isDownloadedFileExists(int id) {
    if (_isDownloadedFileExistsCache.containsKey(id)) {
      return _isDownloadedFileExistsCache[id]!;
    }

    final item = _downloadedItems[id];
    if (item == null) return false;

    final files = item.filesWithoutThumbnail();
    if (files.isEmpty) {
      _isDownloadedFileExistsCache[id] = false;
      return false;
    }

    final exists = File(files[0]).existsSync();
    _isDownloadedFileExistsCache[id] = exists;
    return exists;
  }

  void appendDownloaded(int id, DownloadItemModel item) {
    _downloadedChecker.add(id);
    _downloadedItems[id] = item;
    _isDownloadedFileExistsCache.remove(id);
  }

  void removeDownloaded(int id) {
    _downloadedChecker.remove(id);
    _downloadedItems.remove(id);
    _isDownloadedFileExistsCache.remove(id);
  }

  DownloadItemModel? getDownloadedArticle(int id) => _downloadedItems[id];

  Future<List<DownloadItemModel>> getDownloadItems() async {
    return (await (await CommonUserDatabase.getInstance()).query(
      'SELECT * FROM DownloadItem',
    )).map((x) => DownloadItemModel(result: Map<String, dynamic>.from(x))).toList();
  }

  Future<DownloadItemModel> createNew(
    String url, {
    QueryResult? queryResult,
    String? info,
    String? thumbnail,
    String? thumbnailHeader,
  }) async {
    final rr = <String, dynamic>{
      'URL': url,
      'State': 1,
      'DateTime': DateTime.now().toString(),
      if (info != null) 'Info': info,
      if (thumbnail != null) 'Thumbnail': thumbnail,
      if (thumbnailHeader != null) 'ThumbnailHeader': thumbnailHeader,
      if (queryResult != null) 'Metadata': jsonEncode(queryResult.result),
    };
    var db = await CommonUserDatabase.getInstance();
    await db.insert('DownloadItem', rr);
    var ll = (await db.query(
      'SELECT * FROM DownloadItem ORDER BY Id DESC LIMIT 1',
    ))[0];
    final model = DownloadItemModel(result: Map<String, dynamic>.from(ll));
    model.queryResult = queryResult;
    return model;
  }

  Future<void> clear() async {
    var db = await CommonUserDatabase.getInstance();
    await db.delete('DownloadItem', 'Id=?', [1]);
    await db.delete('DownloadItem', 'Id=?', [0]);
  }
}
