// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:violet/component/downloadable.dart';
import 'package:violet/downloader/isolate_downloader.dart';

void main() {
  test('IsolateDownloader downloads file from local HTTP server and creates parent dirs', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = List<int>.generate(2048, (i) => i % 256);

    server.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });

    final tempDir = await Directory.systemTemp.createTemp('violet_dl_test_');
    final targetPath = p.join(tempDir.path, 'nested', '12345', '000.bin');

    final downloader = await IsolateDownloader.getInstance();
    await downloader.waitUntilReady();

    final completed = Completer<void>();
    String? errorMsg;

    final task = DownloadTask(
      url: 'http://127.0.0.1:${server.port}/000.bin',
      downloadPath: targetPath,
    )
      ..completeCallback = () {
        if (!completed.isCompleted) completed.complete();
      }
      ..errorCallback = (err) {
        errorMsg = err;
        if (!completed.isCompleted) completed.complete();
      };

    downloader.appendTask(task);
    await completed.future.timeout(const Duration(seconds: 10));

    expect(errorMsg, isNull);
    final outFile = File(targetPath);
    expect(await outFile.exists(), isTrue);
    expect(await outFile.length(), payload.length);

    await server.close(force: true);
    await tempDir.delete(recursive: true);
  });
}
