// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:violet/component/index.dart';
import 'package:violet/log/log.dart';
import 'package:violet/src/rust/api/index_sync.dart' as rust_index_sync;
import 'package:violet/src/rust/frb_generated.dart';

class ChunkIncrementalSyncResult {
  final int downloadedChunks;
  final int upsertedRows;
  final int deletedRows;
  final bool ftsUpdated;
  final bool tagIndexUpdated;
  final int elapsedMs;

  const ChunkIncrementalSyncResult({
    required this.downloadedChunks,
    required this.upsertedRows,
    required this.deletedRows,
    required this.ftsUpdated,
    required this.tagIndexUpdated,
    required this.elapsedMs,
  });
}

/// 원작자 `fast-hsync/db.go` 및 `fts-indexer.ts` 아키텍처 기반 앱 클라이언트 초고속 증분 인덱스 동기화 서비스.
class IncrementalIndexSyncService {
  static bool isFtsTagsReady = false;
  static bool isFtsTitleReady = false;

  static bool get _useRust {
    try {
      return RustLib.instance.initialized;
    } catch (_) {
      return false;
    }
  }

  /// 파이프(`|`) 구분 문자열을 FTS5 토큰(`tokenchars ':_'`) 문자열로 변환합니다.
  /// 예: "|female:sole female|full color|" -> "female:sole_female full_color"
  static String normalizePipedForFts(dynamic raw) {
    if (raw == null) return '';
    final s = raw.toString();
    if (s.isEmpty) return '';
    return s
        .split('|')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) => e.replaceAll(' ', '_'))
        .join(' ');
  }

  /// DB 오픈 직후 호출: WAL 모드 및 B-Tree 커버링 인덱스를 보장하고 기존 FTS5 테이블 존재 여부를 확인합니다.
  static Future<void> initializeOnOpen(Database db) async {
    try {
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.execute('PRAGMA synchronous = NORMAL');
    } catch (_) {}

    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='HitomiColumnModel'",
      );
      if (tables.isEmpty) return;

      await ensureBaseIndexes(db);
      await refreshFtsStatus(db);

      // 빈 더미 DB(초기 상태)라면 0.5ms 내에 빈 FTS5 가상 테이블을 미리 생성해 두어 이후 청크부터 자동 증분 색인
      if (!isFtsTagsReady) {
        final cntRows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM HitomiColumnModel',
        );
        final cnt = (cntRows.first['c'] as num?)?.toInt() ?? 0;
        if (cnt == 0) {
          await ensureFtsTables(db, rebuildExisting: false);
        }
      }
    } catch (e) {
      Logger.warning('[IncrementalIndexSync] initializeOnOpen skipped: $e');
    }
  }

  static Future<void> ensureBaseIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_language_exist_id ON HitomiColumnModel(Language, ExistOnHitomi, Id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_language ON HitomiColumnModel(Language)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_type ON HitomiColumnModel(Type)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_class ON HitomiColumnModel(Class)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_uploader ON HitomiColumnModel(Uploader COLLATE NOCASE)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_exist_id ON HitomiColumnModel(ExistOnHitomi, Id DESC)',
    );
  }

  static Future<void> refreshFtsStatus(Database db) async {
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('FtsTags', 'FtsTitle')",
      );
      final names = rows.map((r) => r['name'].toString()).toSet();
      isFtsTagsReady = names.contains('FtsTags');
      isFtsTitleReady = names.contains('FtsTitle');
    } catch (_) {
      isFtsTagsReady = false;
      isFtsTitleReady = false;
    }
  }

  /// FTS5 가상 테이블(`FtsTags`, `FtsTitle`)을 생성하며, `rebuildExisting: true`일 때 기존 행을 적재합니다.
  static Future<void> ensureFtsTables(
    Database db, {
    bool rebuildExisting = true,
  }) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS FtsTags USING fts5(
          Tags, Artists, Groups_, Series, Characters,
          tokenize="unicode61 tokenchars ':_'"
        )
      ''');
      isFtsTagsReady = true;
    } catch (e) {
      isFtsTagsReady = false;
      Logger.warning('[IncrementalIndexSync] FtsTags unsupported: $e');
    }

    try {
      await db.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS FtsTitle USING fts5(Title, tokenize='trigram')",
      );
      isFtsTitleReady = true;
    } catch (e) {
      isFtsTitleReady = false;
    }

    if (!rebuildExisting || (!isFtsTagsReady && !isFtsTitleReady)) return;

    final existingRows = await db.rawQuery(
      'SELECT Id, Title, Tags, Artists, "Groups", Series, Characters '
      'FROM HitomiColumnModel WHERE ExistOnHitomi = 1',
    );
    if (existingRows.isEmpty) return;

    await db.transaction((txn) async {
      if (isFtsTagsReady) await txn.execute('DELETE FROM FtsTags');
      if (isFtsTitleReady) await txn.execute('DELETE FROM FtsTitle');
      final batch = txn.batch();
      for (final row in existingRows) {
        final id = row['Id'];
        if (isFtsTitleReady) {
          batch.rawInsert(
            'INSERT INTO FtsTitle(rowid, Title) VALUES (?, ?)',
            [id, (row['Title'] ?? '').toString()],
          );
        }
        if (isFtsTagsReady) {
          batch.rawInsert(
            'INSERT INTO FtsTags(rowid, Tags, Artists, Groups_, Series, Characters) VALUES (?, ?, ?, ?, ?, ?)',
            [
              id,
              normalizePipedForFts(row['Tags']),
              normalizePipedForFts(row['Artists']),
              normalizePipedForFts(row['Groups']),
              normalizePipedForFts(row['Series']),
              normalizePipedForFts(row['Characters']),
            ],
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  static bool isRowDiff(Map<String, dynamic> oldRow, Map<String, dynamic> newRow) {
    const keys = [
      'Title', 'Artists', 'Groups', 'Uploader', 'Tags',
      'Characters', 'Series', 'Language', 'Type', 'Files',
      'Class', 'ExistOnHitomi',
    ];
    for (final k in keys) {
      final a = (oldRow[k] ?? '').toString();
      final b = (newRow[k] ?? '').toString();
      if (a != b) return true;
    }
    return false;
  }

  static Future<Map<int, Map<String, dynamic>>> _fetchExistingByIds(
    DatabaseExecutor db,
    List<int> ids,
  ) async {
    final result = <int, Map<String, dynamic>>{};
    if (ids.isEmpty) return result;

    for (var i = 0; i < ids.length; i += 500) {
      final end = (i + 500 < ids.length) ? i + 500 : ids.length;
      final sub = ids.sublist(i, end);
      final placeholders = List.filled(sub.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT Id, Title, Artists, "Groups", Type, Language, Series, Characters, '
        'Tags, Files, Uploader, Class, ExistOnHitomi '
        'FROM HitomiColumnModel WHERE Id IN ($placeholders)',
        sub,
      );
      for (final r in rows) {
        final id = (r['Id'] as num).toInt();
        result[id] = r;
      }
    }
    return result;
  }

  static Future<void> _updateFtsRowsInTxn(
    Transaction txn,
    List<Map<String, dynamic>> upsertedRows,
    List<int> deletedIds,
  ) async {
    if (!isFtsTagsReady && !isFtsTitleReady) return;

    final allIdsToDelete = <int>{
      ...deletedIds,
      ...upsertedRows.map((r) => (r['Id'] as num).toInt()),
    }.toList();

    for (var i = 0; i < allIdsToDelete.length; i += 500) {
      final end = (i + 500 < allIdsToDelete.length)
          ? i + 500
          : allIdsToDelete.length;
      final sub = allIdsToDelete.sublist(i, end);
      final ph = List.filled(sub.length, '?').join(',');
      if (isFtsTitleReady) {
        await txn.rawDelete('DELETE FROM FtsTitle WHERE rowid IN ($ph)', sub);
      }
      if (isFtsTagsReady) {
        await txn.rawDelete('DELETE FROM FtsTags WHERE rowid IN ($ph)', sub);
      }
    }

    if (upsertedRows.isEmpty) return;
    final batch = txn.batch();
    for (final row in upsertedRows) {
      final exist = row['ExistOnHitomi'];
      if (exist != null && exist.toString() == '0') continue;
      final id = (row['Id'] as num).toInt();
      if (isFtsTitleReady) {
        batch.rawInsert(
          'INSERT INTO FtsTitle(rowid, Title) VALUES (?, ?)',
          [id, (row['Title'] ?? '').toString()],
        );
      }
      if (isFtsTagsReady) {
        batch.rawInsert(
          'INSERT INTO FtsTags(rowid, Tags, Artists, Groups_, Series, Characters) VALUES (?, ?, ?, ?, ?, ?)',
          [
            id,
            normalizePipedForFts(row['Tags']),
            normalizePipedForFts(row['Artists']),
            normalizePipedForFts(row['Groups']),
            normalizePipedForFts(row['Series']),
            normalizePipedForFts(row['Characters']),
          ],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  static Future<String> _resolveIndexDir() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return p.join(Directory.current.path, 'test', 'db');
    }
    final dir = await getApplicationDocumentsDirectory();
    final sub = Platform.isAndroid ? p.join(dir.path, 'data') : dir.path;
    final d = Directory(sub);
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return sub;
  }

  static void _applyMapDeltaDart(
    Map<String, dynamic> map,
    String? rawVal,
    int delta, {
    bool piped = true,
  }) {
    if (rawVal == null || rawVal.isEmpty || delta == 0) return;
    final items = piped
        ? rawVal.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty)
        : [rawVal.trim()].where((e) => e.isNotEmpty);
    for (final k in items) {
      final prev = (map[k] as num?)?.toInt() ?? 0;
      final next = prev + delta;
      if (next <= 0) {
        map.remove(k);
      } else {
        map[k] = next;
      }
    }
  }

  static Future<void> _applyIndexDeltaFallbackDart(
    String dataDir,
    List<Map<String, dynamic>> removed,
    List<Map<String, dynamic>> added,
  ) async {
    final indexFile = File(p.join(dataDir, 'index.json'));
    Map<String, dynamic> root = {};
    if (await indexFile.exists()) {
      try {
        root = jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }
    Map<String, dynamic> subMap(String k) => (root[k] is Map)
        ? Map<String, dynamic>.from(root[k] as Map)
        : <String, dynamic>{};

    final mTag = subMap('tag');
    final mArtist = subMap('artist');
    final mGroup = subMap('group');
    final mSeries = subMap('series');
    final mLang = subMap('lang');
    final mType = subMap('type');
    final mUploader = subMap('uploader');
    final mChar = subMap('character');
    final mClass = subMap('class');

    void applyList(List<Map<String, dynamic>> rows, int d) {
      for (final r in rows) {
        _applyMapDeltaDart(mTag, r['Tags']?.toString(), d);
        _applyMapDeltaDart(mArtist, r['Artists']?.toString(), d);
        _applyMapDeltaDart(mGroup, r['Groups']?.toString(), d);
        _applyMapDeltaDart(mSeries, r['Series']?.toString(), d);
        _applyMapDeltaDart(mChar, r['Characters']?.toString(), d);
        _applyMapDeltaDart(mLang, r['Language']?.toString(), d, piped: false);
        _applyMapDeltaDart(mType, r['Type']?.toString(), d, piped: false);
        _applyMapDeltaDart(mUploader, r['Uploader']?.toString(), d, piped: false);
        _applyMapDeltaDart(mClass, r['Class']?.toString(), d, piped: false);
      }
    }

    applyList(removed, -1);
    applyList(added, 1);

    final out = {
      'tag': mTag,
      'artist': mArtist,
      'group': mGroup,
      'series': mSeries,
      'lang': mLang,
      'type': mType,
      'uploader': mUploader,
      'character': mChar,
      'class': mClass,
    };
    final tmp = File('${indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(out), flush: true);
    if (await indexFile.exists()) await indexFile.delete();
    await tmp.rename(indexFile.path);
  }

  /// 원격 청크 레코드 묶음을 받아 변경분만 SQLite + FTS5 + 로컬 태그 JSON 인덱스에 고속 증분 반영합니다.
  static Future<ChunkIncrementalSyncResult> applyChunksIncrementally(
    Database db,
    List<Map<String, dynamic>> chronologicalRecords, {
    int chunkCount = 1,
    String? deleteWhereClause,
    String? customIndexDir,
    bool reloadMemoryIndex = true,
  }) async {
    final sw = Stopwatch()..start();
    await ensureBaseIndexes(db);
    await refreshFtsStatus(db);

    final latestById = <int, Map<String, dynamic>>{};
    for (final r in chronologicalRecords) {
      final rawId = r['Id'];
      if (rawId == null) continue;
      final id = rawId is int ? rawId : int.tryParse(rawId.toString());
      if (id == null) continue;
      final copy = Map<String, dynamic>.from(r);
      copy['Id'] = id;
      latestById[id] = copy;
    }

    final existingMap = await _fetchExistingByIds(db, latestById.keys.toList());
    final toUpsert = <Map<String, dynamic>>[];
    final removedForDelta = <Map<String, dynamic>>[];
    final addedForDelta = <Map<String, dynamic>>[];

    for (final entry in latestById.entries) {
      final id = entry.key;
      final incoming = entry.value;
      final old = existingMap[id];
      if (old == null) {
        toUpsert.add(incoming);
        addedForDelta.add(incoming);
      } else if (isRowDiff(old, incoming)) {
        toUpsert.add(incoming);
        removedForDelta.add(old);
        addedForDelta.add(incoming);
      }
    }

    var deletedIds = <int>[];
    if (deleteWhereClause != null && deleteWhereClause.trim().isNotEmpty) {
      final deletedRows = await db.rawQuery(
        'SELECT Id, Title, Artists, "Groups", Type, Language, Series, Characters, '
        'Tags, Files, Uploader, Class, ExistOnHitomi '
        'FROM HitomiColumnModel WHERE $deleteWhereClause',
      );
      for (final dr in deletedRows) {
        final id = (dr['Id'] as num).toInt();
        deletedIds.add(id);
        removedForDelta.add(dr);
      }
    }

    if (toUpsert.isNotEmpty || deletedIds.isNotEmpty) {
      await db.transaction((txn) async {
        if (toUpsert.isNotEmpty) {
          final batch = txn.batch();
          for (final row in toUpsert) {
            batch.insert(
              'HitomiColumnModel',
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: true);
        }

        if (deleteWhereClause != null && deletedIds.isNotEmpty) {
          await txn.delete('HitomiColumnModel', where: deleteWhereClause);
        }

        await _updateFtsRowsInTxn(txn, toUpsert, deletedIds);
      });
    }

    bool tagIndexUpdated = false;
    if (removedForDelta.isNotEmpty || addedForDelta.isNotEmpty) {
      final dataDir = customIndexDir ?? await _resolveIndexDir();
      if (await File(p.join(dataDir, 'index.json')).exists() ||
          customIndexDir != null) {
        if (_useRust) {
          await rust_index_sync.applyIndexDelta(
            dataDir: dataDir,
            removedRowsJson: jsonEncode(removedForDelta),
            addedRowsJson: jsonEncode(addedForDelta),
          );
        } else {
          await _applyIndexDeltaFallbackDart(
            dataDir,
            removedForDelta,
            addedForDelta,
          );
        }
        tagIndexUpdated = true;
        if (reloadMemoryIndex) {
          await HentaiIndex.reloadFromDisk();
        }
      }
    }

    sw.stop();
    return ChunkIncrementalSyncResult(
      downloadedChunks: chunkCount,
      upsertedRows: toUpsert.length,
      deletedRows: deletedIds.length,
      ftsUpdated: isFtsTagsReady || isFtsTitleReady,
      tagIndexUpdated: tagIndexUpdated,
      elapsedMs: sw.elapsedMilliseconds,
    );
  }
}