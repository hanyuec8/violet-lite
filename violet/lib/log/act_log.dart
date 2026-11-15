// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart' as sync;

enum ActLogType {
  none,
  // signal
  signal,
  // on/off
  appStart,
  appSuspense,
  appResume,
  appStop,
  // // after loading
  // pageSwipe,
  // serviceButton,
  // databaseSync,
  // databaseSwitching,
  // // search
  // openSearch,
  // searchWhat,
  // searchTypeChange,
  // filterOn,
  // filterData,
  // // bookmark
  // articleBookmark,
  // artistBookmark,
  // openBookmarkGroup,
  // moveBookmarkArticle,
  // addBookmarkGroup,
  // removeBookmarkGroup,
  // // settings
  // settingChange,
  // // article
  // openArticleInfo,
  // openArtistInfo,
  // downloadArticle,
  // readArticle,
  // // download
  // readDownloadedArticle,
  // // viewer
  // viewStart,
  // viewEnd,
  // viewTab,
  // viewTabReplace,
  // viewBookmark,
  // viewOpenArticleInfo,
  // viewOpenSettingInfo,
  // viewThumbnail,
  // viewThumbnailJump,
  // viewSlide,
  // viewThumbBar,
}

class ActLogEvent {
  DateTime? dateTime;
  String? detail;
  ActLogType type;

  ActLogEvent({this.dateTime, this.detail, required this.type}) {
    dateTime ??= DateTime.now();
  }

  toJson() {
    return jsonEncode({
      'dt': dateTime.toString(),
      'type': type.toString(),
      'detail': detail,
    });
  }

  static ActLogEvent fromJson(String json) {
    final obj = jsonDecode(json);
    return ActLogEvent(
      type: ActLogType.values.byName((obj['type'] as String).split('.')[1]),
      dateTime: DateTime.parse(obj['dt']),
      detail: obj['detail'],
    );
  }
}

// this data is stored only on local storage
// for user data statistics
class ActLogger {
  // Since isolates handle all asynchronous operations linearly,
  // there is no need for mutual exclusion.
  static sync.Lock lock = sync.Lock();
  static late File logFile;

  /// this session is refreshed every app restarting.
  static late String session;
  static List<ActLogEvent> events = <ActLogEvent>[];

  static Timer? signalTimer;

  static Future<void> init() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      logFile = File('act-log.txt');
    } else {
      final dir = await getApplicationDocumentsDirectory();
      logFile = File(join(dir.path, 'act-log.txt'));
    }

    if (!await logFile.exists()) {
      await logFile.create();
    } else {
      final len = await logFile.length();
      if (len > 2 * 1024 * 1024) {
        try {
          final raf = await logFile.open(mode: FileMode.read);
          await raf.setPosition(len - 512 * 1024);
          final tailBytes = await raf.read(512 * 1024);
          await raf.close();
          await logFile.writeAsBytes(tailBytes, mode: FileMode.write);
        } catch (_) {}
      }
    }

    session = sha1.convert(utf8.encode(DateTime.now().toString())).toString();
    await log(ActLogEvent(type: ActLogType.appStart));

    signalTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      log(ActLogEvent(type: ActLogType.signal));
    });
  }

  static Future<void> log(ActLogEvent msg) async {
    print('$session ${msg.toJson()}');

    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      await lock.synchronized(() async {
        events.add(msg);
        if (events.length > 2000) {
          events.removeRange(0, events.length - 1000);
        }
        await logFile.writeAsString(
          '$session ${msg.toJson()}\n',
          mode: FileMode.append,
        );
      });
    }
  }

  static Future<void> exportLog() async {
    final ext = Platform.isIOS
        ? await getApplicationSupportDirectory()
        : await getExternalStorageDirectory();
    final extpath = '${ext!.path}/act-log.txt';
    await logFile.copy(extpath);
  }
}
