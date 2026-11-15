// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/incremental_index_sync.dart';
import 'package:violet/src/rust/frb_generated.dart';

void main() {
  late Directory tempDir;
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    if (Platform.isWindows &&
        File('rust/target/debug/rust_lib_violet.dll').existsSync()) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          'rust/target/debug/rust_lib_violet.dll',
        ),
      );
    }
    tempDir = await Directory.systemTemp.createTemp('violet_inc_sync_test_');
    final dbPath = p.join(tempDir.path, 'data.db');
    db = await databaseFactoryFfi.openDatabase(dbPath);
    await db.execute('''
      CREATE TABLE HitomiColumnModel (
        Id INTEGER PRIMARY KEY,
        Title TEXT,
        EHash TEXT,
        Type TEXT,
        Artists TEXT,
        Characters TEXT,
        Groups TEXT,
        Language TEXT,
        Tags TEXT,
        Uploader TEXT,
        Published TEXT,
        Files INTEGER,
        Class TEXT,
        ExistOnHitomi INTEGER,
        Series TEXT,
        PublishedEH TEXT,
        Thumbnail TEXT,
        URL TEXT
      )
    ''');
    await IncrementalIndexSyncService.initializeOnOpen(db);
  });

  tearDownAll(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('incrementally syncs chunks, updates FTS5 & tag JSON deltas, and skips unchanged rows', () async {
    final idxDir = p.join(tempDir.path, 'idx');
    await Directory(idxDir).create(recursive: true);

    final chunk1 = [
      {
        'Id': 5001,
        'Title': '환상의 엘프 이야기',
        'Artists': '|nishi|',
        'Tags': '|female:elf|full color|',
        'Language': 'korean',
        'Type': 'doujinshi',
        'Files': 32,
        'ExistOnHitomi': 1,
      },
      {
        'Id': 5002,
        'Title': '학원 순애 단편집',
        'Artists': '|alpha|',
        'Tags': '|female:sole female|male:sole male|',
        'Language': 'korean',
        'Type': 'manga',
        'Files': 24,
        'ExistOnHitomi': 1,
      },
    ];

    final res1 = await IncrementalIndexSyncService.applyChunksIncrementally(
      db,
      chunk1,
      customIndexDir: idxDir,
      reloadMemoryIndex: false,
    );
    expect(res1.upsertedRows, equals(2));
    expect(res1.tagIndexUpdated, isTrue);

    // 동일 청크 재수신 시 변경분 0건으로 스킵 검증
    final resSame = await IncrementalIndexSyncService.applyChunksIncrementally(
      db,
      chunk1,
      customIndexDir: idxDir,
      reloadMemoryIndex: false,
    );
    expect(resSame.upsertedRows, equals(0));

    // FTS5 가속 쿼리 검증
    final sql = translate2query('female:elf lang:korean');
    final rows = await db.rawQuery(sql);
    expect(rows.map((r) => r['Id']), equals([5001]));

    // 수정(5001에서 full color 제거, series 추가) + 삭제(5002 제거) 증분 반영 검증
    final chunk2 = [
      {
        'Id': 5001,
        'Title': '환상의 엘프 이야기 개정판',
        'Artists': '|nishi|',
        'Tags': '|female:elf|',
        'Series': '|original|',
        'Language': 'korean',
        'Type': 'doujinshi',
        'Files': 36,
        'ExistOnHitomi': 1,
      },
    ];
    final res2 = await IncrementalIndexSyncService.applyChunksIncrementally(
      db,
      chunk2,
      deleteWhereClause: 'Id = 5002',
      customIndexDir: idxDir,
      reloadMemoryIndex: false,
    );
    expect(res2.upsertedRows, equals(1));
    expect(res2.deletedRows, equals(1));

    final indexJson = jsonDecode(
      await File(p.join(idxDir, 'index.json')).readAsString(),
    ) as Map<String, dynamic>;
    final tagMap = indexJson['tag'] as Map<String, dynamic>;
    expect(tagMap['female:elf'], equals(1));
    expect(tagMap.containsKey('full color'), isFalse);
    expect(tagMap.containsKey('female:sole female'), isFalse);
  });
}
