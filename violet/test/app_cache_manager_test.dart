// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:violet/component/app_cache_manager.dart';

void main() {
  test('trims LRU cache directory down to target byte budget', () async {
    final dir = await Directory.systemTemp.createTemp('violet_cache_lru_');
    try {
      final f1 = File(p.join(dir.path, 'old.bin'));
      final f2 = File(p.join(dir.path, 'mid.bin'));
      final f3 = File(p.join(dir.path, 'new.bin'));
      await f1.writeAsBytes(List.filled(400, 1));
      await f2.writeAsBytes(List.filled(400, 2));
      await f3.writeAsBytes(List.filled(400, 3));

      final now = DateTime.now();
      await f1.setLastModified(now.subtract(const Duration(hours: 3)));
      await f2.setLastModified(now.subtract(const Duration(hours: 2)));
      await f3.setLastModified(now.subtract(const Duration(hours: 1)));

      await AppCacheManager.trimDirectoryLruForTest(
        dir,
        maxBytes: 900,
        targetBytes: 500,
      );

      expect(await f1.exists(), isFalse);
      expect(await f2.exists(), isFalse);
      expect(await f3.exists(), isTrue);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('removes stale cache files older than maxAge', () async {
    final dir = await Directory.systemTemp.createTemp('violet_cache_stale_');
    try {
      final stale = File(p.join(dir.path, 'stale.bin'));
      final fresh = File(p.join(dir.path, 'fresh.bin'));
      await stale.writeAsBytes(const [1, 2, 3]);
      await fresh.writeAsBytes(const [4, 5, 6]);

      final now = DateTime.now();
      await stale.setLastModified(now.subtract(const Duration(hours: 10)));
      await fresh.setLastModified(now.subtract(const Duration(minutes: 10)));

      await AppCacheManager.deleteStaleFilesForTest(
        dir,
        const Duration(hours: 6),
      );

      expect(await stale.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });
}
