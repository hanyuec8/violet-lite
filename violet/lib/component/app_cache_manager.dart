// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:violet/component/hitomi/message_corpus_manager.dart';
import 'package:violet/log/log.dart';

/// Violet Lite 기조에 맞춘 디스크·메모리 캐시 상한 관리 및 자동 정리기.
class AppCacheManager {
  AppCacheManager._();

  /// 전체 이미지 디스크 캐시 합산 상한 (100 MB) 및 정리 목표치
  static const int maxTotalDiskCacheBytes = 100 * 1024 * 1024;
  static const int maxViewerDiskCacheBytes = 55 * 1024 * 1024;
  static const int targetViewerDiskCacheBytes = 35 * 1024 * 1024;
  static const int maxThumbDiskCacheBytes = 45 * 1024 * 1024;

  static const Duration viewerCacheMaxAge = Duration(hours: 6);
  static const Duration thumbCacheMaxAge = Duration(days: 2);

  static Future<void>? _inflight;

  /// 앱 시작 시 또는 뷰어 종료 시 백그라운드로 캐시 용량 상한을 적용합니다.
  static Future<void> enforceBudget() {
    if (_inflight != null) return _inflight!;
    final future = _enforceBudgetInternal().whenComplete(() {
      _inflight = null;
    });
    _inflight = future;
    return future;
  }

  static Future<void> _enforceBudgetInternal() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;

      // 1) ExtendedImage 디스크 캐시(cacheimage): 6시간 경과 파일 삭제 + 55MB 초과 시 LRU 정리
      try {
        await clearDiskCachedImages(duration: viewerCacheMaxAge);
      } catch (_) {}

      final cacheImageDir = Directory(p.join(tempDir.path, cacheImageFolderName));
      await _trimDirectoryLru(
        cacheImageDir,
        maxBytes: maxViewerDiskCacheBytes,
        targetBytes: targetViewerDiskCacheBytes,
      );

      // 2) flutter_cache_manager(libCachedImageData): 만료 파일 또는 45MB 초과 시 정리
      final libCacheDir = Directory(p.join(tempDir.path, 'libCachedImageData'));
      if (await libCacheDir.exists()) {
        final libBytes = await _directorySize(libCacheDir);
        if (libBytes > maxThumbDiskCacheBytes) {
          try {
            await DefaultCacheManager().emptyCache();
          } catch (_) {}
        } else {
          await _deleteStaleFiles(libCacheDir, thumbCacheMaxAge);
        }
      }

      // 3) 임시 잔여 파일(.apk / .tmp) 정리
      await _cleanLeftoverTempFiles(tempDir);
    } catch (e, st) {
      Logger.error('[AppCacheManager] enforceBudget failed: $e\n$st');
    }
  }

  /// 사용자가 설정에서 캐시 비우기를 실행할 때 모든 이미지·임시 캐시를 즉시 비웁니다.
  static Future<void> clearAllCaches() async {
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}

    try {
      clearMemoryImageCache();
    } catch (_) {}

    try {
      await clearDiskCachedImages();
    } catch (_) {}

    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {}

    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;

      for (final name in [cacheImageFolderName, 'libCachedImageData']) {
        final d = Directory(p.join(tempDir.path, name));
        if (await d.exists()) {
          try {
            await d.delete(recursive: true);
          } catch (_) {}
        }
      }
      await _cleanLeftoverTempFiles(tempDir);
    } catch (e) {
      Logger.error('[AppCacheManager] clearAllCaches failed: $e');
    }
  }

  /// 현재 이미지 및 임시 디스크 캐시 총 크기(bytes)를 계산합니다.
  static Future<int> calculateCacheSizeBytes() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return 0;
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return 0;

      int total = 0;
      for (final name in [cacheImageFolderName, 'libCachedImageData']) {
        final d = Directory(p.join(tempDir.path, name));
        if (await d.exists()) {
          total += await _directorySize(d);
        }
      }
      await for (final entity in tempDir.list(followLinks: false)) {
        if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.apk') || lower.endsWith('.tmp')) {
            try {
              total += await entity.length();
            } catch (_) {}
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _directorySize(Directory dir) async {
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  static Future<void> _deleteStaleFiles(Directory dir, Duration maxAge) async {
    final cutoff = DateTime.now().subtract(maxAge);
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete();
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  @visibleForTesting
  static Future<void> trimDirectoryLruForTest(
    Directory dir, {
    required int maxBytes,
    required int targetBytes,
  }) =>
      _trimDirectoryLru(dir, maxBytes: maxBytes, targetBytes: targetBytes);

  @visibleForTesting
  static Future<void> deleteStaleFilesForTest(
    Directory dir,
    Duration maxAge,
  ) =>
      _deleteStaleFiles(dir, maxAge);

  static Future<void> _trimDirectoryLru(
    Directory dir, {
    required int maxBytes,
    required int targetBytes,
  }) async {
    if (!await dir.exists()) return;
    final entries = <(File file, DateTime modified, int size)>[];
    int total = 0;

    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            total += stat.size;
            entries.add((entity, stat.modified, stat.size));
          } catch (_) {}
        }
      }
    } catch (_) {
      return;
    }

    if (total <= maxBytes) return;

    entries.sort((a, b) => a.$2.compareTo(b.$2));
    for (final entry in entries) {
      if (total <= targetBytes) break;
      try {
        await entry.$1.delete();
        total -= entry.$3;
      } catch (_) {}
    }
  }

  static Future<void> _cleanLeftoverTempFiles(Directory tempDir) async {
    final corpusBusy = MessageCorpusManager.instance.isBusy;
    try {
      await for (final entity in tempDir.list(followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path).toLowerCase();
          if (name.endsWith('.apk') ||
              (name.endsWith('.tmp') &&
                  !(corpusBusy && name == 'corpus_download.tmp'))) {
            try {
              final stat = await entity.stat();
              if (DateTime.now().difference(stat.modified) >
                  const Duration(minutes: 30)) {
                await entity.delete();
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
}
