// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/component/downloadable.dart';
import 'package:violet/log/log.dart';

part './isolate/core.dart';

enum DownloadTaskState { wait, append, downloading, complete, error, cancel }

class DownloadTaskStatus {
  final DownloadTaskState state;

  // downloading
  final int? totalSize;
  final int? countSize;

  // error
  final String? errorContent;
  final String? stackTraceContent;

  DownloadTaskStatus({
    required this.state,
    this.totalSize,
    this.countSize,
    this.errorContent,
    this.stackTraceContent,
  });
}

class IsolateDownloader {
  final ReceivePort _receivePort = ReceivePort();
  SendPort? _sendPort;
  final Completer<void> _readyCompleter = Completer<void>();
  late Isolate _isolate;
  late Map<int, DownloadTask> _tasks;
  late int _taskTotalCount;
  late Map<int, int> _taskTotalSizes;
  late Map<int, int> _taskCountSizes;
  late HashSet<int> _appendedTask;
  late HashSet<int> _completedTask;
  late HashSet<int> _erroredTask;
  late HashSet<int> _canceledTask;
  late int _threadCount;
  late Map<int, IsolateDownloaderErrorUnit> _errorContent;

  static IsolateDownloader? _instance;
  static Future<IsolateDownloader> getInstance() async {
    if (_instance == null) {
      _instance = IsolateDownloader();
      await _instance!.init();
    }

    return _instance!;
  }

  Future<void> init() async {
    await _initThreadCount();
    _receivePort.listen((dynamic message) => _listen(message));
    _isolate = await Isolate.spawn(
      _downloadIsolateRoutine,
      _receivePort.sendPort,
    );
    _tasks = <int, DownloadTask>{};
    _taskTotalSizes = <int, int>{};
    _taskCountSizes = <int, int>{};
    _appendedTask = HashSet<int>();
    _completedTask = HashSet<int>();
    _erroredTask = HashSet<int>();
    _canceledTask = HashSet<int>();
    _errorContent = <int, IsolateDownloaderErrorUnit>{};
    _taskTotalCount = 0;
  }

  Future<void> _initThreadCount() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _threadCount = 8;
    } else {
      final prefs = await SharedPreferences.getInstance();
      var tc = prefs.getInt('thread_count');
      if (tc == null) {
        tc = 4;
        await prefs.setInt('thread_count', 4);
      }
      if (tc > 128) {
        tc = 128;
        await prefs.setInt('thread_count', 128);
      }
      _threadCount = tc;
    }
  }

  bool isReady() => _sendPort != null;

  Future<void> waitUntilReady() async {
    if (_sendPort != null) return;
    await _readyCompleter.future;
  }

  Future<void> _listen(dynamic message) async {
    if (message is SendPort) {
      _sendPort = message;
      _sendPort!.send(
        SendPortData(
          type: SendPortType.init,
          data: IsolateDownloaderOption(
            threadCount: _threadCount,
            maxRetryCount: 10,
          ),
        ),
      );
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
    } else if (message is ReceivePortData) {
      switch (message.type) {
        case ReceivePortType.append:
          _appendedTask.add(message.data as int);
          break;
        case ReceivePortType.progresss:
          var unit = message.data as IsolateDownloaderProgressProtocolUnit;
          _progressTask(unit);
          break;
        case ReceivePortType.complete:
          _completeTask(message.data as int);
          break;
        case ReceivePortType.error:
          await _errorTask(message.data as IsolateDownloaderErrorUnit);
          break;
        case ReceivePortType.retry:
          await _retryTask(message.data as Map<dynamic, dynamic>);
          break;
      }
    }
  }

  void changeThreadCount(int threadCount) {
    _threadCount = threadCount;
    _sendPort?.send(
      SendPortData(type: SendPortType.tasksize, data: threadCount),
    );
  }

  void cancel(int taskId) {
    _sendPort?.send(SendPortData(type: SendPortType.cancel, data: taskId));
    _canceledTask.add(taskId);
    _tasks.remove(taskId);
  }

  void close() {
    _sendPort?.send(const SendPortData(type: SendPortType.terminate));
    _isolate.kill(priority: Isolate.immediate);
    _receivePort.close();
  }

  void appendTask(DownloadTask task) {
    task.taskId = _taskTotalCount++;
    _tasks[task.taskId] = task;
    _sendPort!.send(
      SendPortData(
        type: SendPortType.append,
        data: IsolateDownloaderTask.fromDownloadTask(task.taskId, task),
      ),
    );
  }

  void appendTasks(List<DownloadTask> tasks) {
    for (var task in tasks) {
      appendTask(task);
    }
  }

  DownloadTaskStatus getStatus(int taskId) {
    if (_appendedTask.contains(taskId)) {
      if (_canceledTask.contains(taskId)) {
        return DownloadTaskStatus(state: DownloadTaskState.cancel);
      }

      if (_erroredTask.contains(taskId)) {
        return DownloadTaskStatus(
          state: DownloadTaskState.error,
          errorContent: _errorContent[taskId]?.error,
          stackTraceContent: _errorContent[taskId]?.stackTrace,
        );
      }

      if (_completedTask.contains(taskId)) {
        return DownloadTaskStatus(state: DownloadTaskState.complete);
      }

      if (_taskCountSizes.containsKey(taskId)) {
        return DownloadTaskStatus(
          state: DownloadTaskState.downloading,
          totalSize: _taskTotalSizes[taskId],
          countSize: _taskCountSizes[taskId],
        );
      }

      return DownloadTaskStatus(state: DownloadTaskState.append);
    }

    return DownloadTaskStatus(state: DownloadTaskState.wait);
  }

  void _progressTask(IsolateDownloaderProgressProtocolUnit unit) {
    final task = _tasks[unit.id];
    if (task == null) return;
    if (!task.isSizeEnsued) {
      task.isSizeEnsued = true;
      if (task.sizeCallback != null) {
        task.sizeCallback!(unit.totalSize.toDouble());
      }
    }
    if (task.downloadCallback != null) {
      task.downloadCallback!(
        (unit.countSize - task.accDownloadSize).toDouble(),
      );
    }
    _taskTotalSizes[unit.id] = unit.totalSize;
    _taskCountSizes[unit.id] = unit.countSize;
    task.accDownloadSize = unit.countSize;
  }

  void _completeTask(int taskId) {
    final task = _tasks[taskId];
    if (task?.completeCallback != null) {
      task!.completeCallback!();
    }
    _taskCountSizes.remove(taskId);
    _taskTotalSizes.remove(taskId);
    _completedTask.add(taskId);
    _tasks.remove(taskId);
  }

  Future<void> _errorTask(IsolateDownloaderErrorUnit unit) async {
    final task = _tasks[unit.id];
    if (task?.errorCallback != null) {
      task!.errorCallback!(unit.error);
    }
    _erroredTask.add(unit.id);
    _errorContent[unit.id] = unit;

    if (task != null) {
      await Logger.error(
        '[downloader-err] URL: ${task.url ?? ''}\n'
        'P: ${task.downloadPath ?? ''}\n'
        'E: ${unit.error}\n'
        '${unit.stackTrace}',
      );
    }

    _tasks.remove(unit.id);
  }

  Future<void> _retryTask(Map<dynamic, dynamic> data) async {
    var id = data['id'] as int;
    var url = data['url'] as String;
    var count = data['count'] as int;
    var code = data['code'] as int?;
    final task = _tasks[id];

    await Logger.warning(
      '[downloader-retry] URL: $url\n'
      'CODE: $code\n'
      'P: ${task?.downloadPath ?? ''}\n'
      'C: $count',
    );
  }
}
