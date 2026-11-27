// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:violet/component/downloadable.dart' as violetd;
import 'package:violet/component/downloadable.dart';
import 'package:violet/component/hentai_download_manager.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/downloader/isolate_downloader.dart';
import 'package:violet/settings/settings.dart';

class DownloadRoutine {
  DownloadItemModel item;
  late Map<String, dynamic> result;
  VoidCallback setStateCallback;
  VoidCallback thumbnailCallback;
  List<violetd.DownloadTask>? tasks;
  violetd.DownloadTask? thumbnailTask;

  DownloadRoutine(this.item, this.setStateCallback, this.thumbnailCallback) {
    result = Map<String, dynamic>.from(item.result);
  }

  Future<bool> checkValidState() async {
    if (item.state() != 1) {
      if (item.state() == 2 || item.state() == 3) {
        await _setState(6);
      }
      return false;
    }
    return true;
  }

  Future<void> selectExtractor() async {
    await _setState(2);
  }

  Future<void> setToStop() async {
    await _setState(6);
  }

  Future<void> setToPending() async {
    await _setState(1);
  }

  Future<void> createTasks({
    required DoubleIntCallback progressCallback,
  }) async {
    try {
      final generalDownloadProgress = GeneralDownloadProgress(
        simpleInfoCallback: (info) async {
          result['Info'] = info;
          item.result = result;
          setStateCallback.call();
        },
        thumbnailCallback: (url, header) async {
          result['Thumbnail'] = url;
          result['ThumbnailHeader'] = header;
          item.result = result;
          thumbnailCallback.call();
        },
        progressCallback: progressCallback,
      );

      final extraction = await HentaiDonwloadManager.instance()
          .createOnlineExtraction(
            item.url(),
            generalDownloadProgress,
            existingQueryResult: item.toQueryResult(),
          );

      if (extraction == null) {
        await _setState(11);
        return;
      }

      // 온라인 메타데이터 스냅샷 영구 저장 (오프라인 열람/검색/정렬 보장)
      item.queryResult = extraction.queryResult;
      result['Metadata'] = jsonEncode(extraction.queryResult.result);
      result['Extractor'] = HentaiDonwloadManager.instance().name();

      tasks = extraction.tasks;
      thumbnailTask = extraction.thumbnailTask;

      final basepath = await downloadBasePath();
      await _ensureNoMediaFile(basepath);

      final rule = HentaiDonwloadManager.instance().defaultFormat();
      for (var task in tasks!) {
        task.downloadPath = join(
          basepath,
          task.format!.formatting(rule),
        );
      }
      if (thumbnailTask != null) {
        thumbnailTask!.downloadPath = join(
          basepath,
          thumbnailTask!.format!.formatting(rule),
        );
        result['LocalThumbnail'] = thumbnailTask!.downloadPath;
      }
    } catch (e) {
      result['ErrorMsg'] = e.toString();
      await _setState(7);
      return;
    }
  }

  Future<bool> checkNothingToDownload() async {
    if (tasks == null || tasks!.isEmpty) {
      await _setState(11);
      return true;
    }
    return false;
  }

  Future<void> extractFilePath() async {
    final files = tasks!.map((e) => e.downloadPath!).toList();
    result['Files'] = jsonEncode(files);
    result['Path'] = _extractSuperPath(files);
    await _updateItem();
  }

  String _extractSuperPath(List<String> files) {
    if (files.isEmpty) return '';
    var cp = split(dirname(files[0]));
    var vp = cp.length;
    for (int i = 1; i < files.length; i++) {
      var tp = split(dirname(files[i]));
      final limit = vp < tp.length ? vp : tp.length;
      vp = limit;
      for (int j = 0; j < limit; j++) {
        if (cp[j] != tp[j]) {
          vp = j;
          break;
        }
      }
    }
    return joinAll(cp.take(vp));
  }

  /// 이미 정상 다운로드된 로컬 파일은 건너뛰고 누락된 페이지만 다운로드 큐에 등록합니다.
  Future<int> appendDownloadTasks({
    required VoidCallback completeCallback,
    required DoubleCallback downloadCallback,
    required VoidStringCallback errorCallback,
    bool skipExistingValidFiles = false,
  }) async {
    final downloader = await IsolateDownloader.getInstance();
    await downloader.waitUntilReady();

    // 대표 썸네일도 로컬에 백그라운드 저장 (오프라인 썸네일 보장)
    if (thumbnailTask != null && thumbnailTask!.downloadPath != null) {
      final thumbFile = File(thumbnailTask!.downloadPath!);
      if (!await thumbFile.exists() || await thumbFile.length() < 5) {
        thumbnailTask!.completeCallback = () {
          result['LocalThumbnail'] = thumbnailTask!.downloadPath;
          item.result = result;
          thumbnailCallback.call();
        };
        thumbnailTask!.errorCallback = (_) {};
        downloader.appendTask(thumbnailTask!);
      }
    }

    final toDownload = <violetd.DownloadTask>[];
    for (final task in tasks!) {
      if (skipExistingValidFiles && task.downloadPath != null) {
        final f = File(task.downloadPath!);
        if (await f.exists() && await f.length() >= 5) {
          completeCallback();
          continue;
        }
      }
      task.startCallback = () {};
      task.completeCallback = completeCallback;
      task.sizeCallback = (byte) {};
      task.downloadCallback = downloadCallback;
      task.errorCallback = errorCallback;
      toDownload.add(task);
    }

    if (toDownload.isNotEmpty) {
      downloader.appendTasks(toDownload);
    }

    await _setState(3);
    return toDownload.length;
  }

  void cancelActiveTasks() {
    if (tasks == null) return;
    final downloader = IsolateDownloader.getInstance();
    downloader.then((d) {
      for (final task in tasks!) {
        try {
          d.cancel(task.taskId);
        } catch (_) {}
      }
    });
  }

  Future<List<int>> checkDownloadFiles() async {
    final files = tasks!.map((e) => e.downloadPath!).toList();
    final invalidIndex = <int>[];

    for (var i = 0; i < files.length; i++) {
      var file = File(files[i]);

      if (!await file.exists()) {
        invalidIndex.add(i);
        continue;
      }

      if (await file.length() < 5) {
        invalidIndex.add(i);
        await file.delete();
        continue;
      }
    }

    return invalidIndex;
  }

  Future<void> retryInvalidDownloadFiles(
    List<int> invalidIndex, {
    required VoidCallback completeCallback,
    required DoubleCallback downloadCallback,
    required VoidStringCallback errorCallback,
  }) async {
    final downloader = await IsolateDownloader.getInstance();
    await downloader.waitUntilReady();

    downloader.appendTasks(
      invalidIndex.map((e) => tasks![e]).map((e) {
        e.startCallback = () {};
        e.completeCallback = completeCallback;
        e.sizeCallback = (byte) {};
        e.downloadCallback = downloadCallback;
        e.errorCallback = errorCallback;
        return e;
      }).toList(),
    );

    await _setState(3);
  }

  Future<void> setDownloadComplete() async {
    final articleId = int.tryParse(item.url());
    if (articleId != null) {
      (await Download.getInstance()).appendDownloaded(articleId, item);
    }
    await _setState(0);
  }

  Future<void> _setState(int state) async {
    result['State'] = state;
    await _updateItem();
  }

  Future<void> _updateItem() async {
    item.result = result;
    await item.update();
    setStateCallback.call();
  }

  Future<String> downloadBasePath() async {
    if (Settings.useInnerStorage.value) {
      return join((await getApplicationDocumentsDirectory()).path, 'downloads');
    } else {
      return Settings.downloadBasePath.value;
    }
  }

  Future<void> _ensureNoMediaFile(String basepath) async {
    if (!Platform.isAndroid) return;
    try {
      final dir = Directory(basepath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final nomedia = File(join(basepath, '.nomedia'));
      if (!await nomedia.exists()) {
        await nomedia.create();
      }
    } catch (_) {}
  }
}
