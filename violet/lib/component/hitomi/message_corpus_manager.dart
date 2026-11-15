// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:violet/component/hitomi/population.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/database.dart';
import 'package:violet/log/log.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/src/rust/api/message_search.dart' as rust_msg;
import 'package:violet/src/rust/api/simple.dart' as rust_simple;

enum CorpusInstallState {
  notInstalled,
  checking,
  downloading,
  extracting,
  verifying,
  ready,
  error,
}

class RemoteCorpusInfo {
  final String url;
  final String versionTag;
  final int compressedBytes;

  const RemoteCorpusInfo({
    required this.url,
    required this.versionTag,
    required this.compressedBytes,
  });
}

class CorpusDownloadProgress {
  final CorpusInstallState state;
  final int receivedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final String message;
  final String? error;

  const CorpusDownloadProgress({
    required this.state,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.message = '',
    this.error,
  });
}

enum DialogueSearchMode { contains, similar }

enum DialogueSortMode { relevance, latest, popular }

/// 한국어 전용 경량 대사 코퍼스(`merged-ko.fscm.7z`) 옵트인 다운로드·검증·생명주기 매니저.
class MessageCorpusManager extends ChangeNotifier {
  static final MessageCorpusManager instance = MessageCorpusManager._();
  MessageCorpusManager._();

  static const String defaultCorpusUrl =
      'https://github.com/hanyuec8/violet-lite/releases/download/database/merged-ko.fscm.7z';
  static const int defaultThreads = 4;

  CorpusInstallState _state = CorpusInstallState.notInstalled;
  CorpusDownloadProgress _progress = const CorpusDownloadProgress(
    state: CorpusInstallState.notInstalled,
  );
  int _recordCount = 0;
  int _localBytes = 0;
  int _maxArticleId = 0;
  CancelToken? _cancelToken;

  CorpusInstallState get state => _state;
  CorpusDownloadProgress get progress => _progress;
  int get recordCount => _recordCount;
  int get localBytes => _localBytes;
  int get maxArticleId => _maxArticleId;
  bool get isReady =>
      Settings.enableMessageSearch.value && _state == CorpusInstallState.ready;
  bool get isBusy =>
      _state == CorpusInstallState.checking ||
      _state == CorpusInstallState.downloading ||
      _state == CorpusInstallState.extracting ||
      _state == CorpusInstallState.verifying;

  void _emit(CorpusDownloadProgress next) {
    _state = next.state;
    _progress = next;
    notifyListeners();
  }

  Future<Directory> getCorpusDir() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      final d = Directory(p.join(Directory.current.path, 'test', 'fscm_tmp'));
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(appDir.path, 'data', 'message_corpus'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<File>> findInstalledFscmFiles() async {
    final dir = await getCorpusDir();
    if (!await dir.exists()) return const [];
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.fscm'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static int getDeviceTotalRamMb() {
    try {
      return rust_msg.deviceTotalRamMb().toInt();
    } catch (_) {
      return 0;
    }
  }

  static int resolveRecommendedBudgetMb() {
    try {
      return rust_msg.recommendedMobileBudgetMb().clamp(128, 1024);
    } catch (_) {
      return 256;
    }
  }

  Future<bool> _verifyAndLoadLocalFiles(List<File> files) async {
    if (files.isEmpty) {
      _recordCount = 0;
      _localBytes = 0;
      _emit(const CorpusDownloadProgress(state: CorpusInstallState.notInstalled));
      return false;
    }

    _emit(const CorpusDownloadProgress(
      state: CorpusInstallState.verifying,
      message: '한국어 대사 레코드 무결성 검증 중...',
    ));

    int totalBytes = 0;
    int maxAid = 0;
    final validPaths = <String>[];
    for (final f in files) {
      final info = await rust_msg.verifyFscmFile(path: f.path);
      if (info.maxArticleId > maxAid) maxAid = info.maxArticleId;
      totalBytes += await f.length();
      validPaths.add(f.path);
    }

    final autoBudget = resolveRecommendedBudgetMb();
    if (Settings.messageSearchMemoryBudgetMb.value != autoBudget) {
      await Settings.messageSearchMemoryBudgetMb.setValue(autoBudget);
    }

    final totalRecs = await rust_msg.mobileSearchInit(
      paths: validPaths,
      budgetMb: autoBudget,
      searchThreads: defaultThreads,
    );

    _recordCount = totalRecs.toInt();
    _localBytes = totalBytes;
    _maxArticleId = maxAid;
    unawaited(ensurePopularRanksSynced());
    _emit(CorpusDownloadProgress(
      state: CorpusInstallState.ready,
      receivedBytes: totalBytes,
      totalBytes: totalBytes,
      message: '준비 완료 ($_recordCount건)',
    ));
    return true;
  }

  Future<void> initIfEnabled() async {
    if (!Settings.enableMessageSearch.value) {
      _state = CorpusInstallState.notInstalled;
      return;
    }
    try {
      final files = await findInstalledFscmFiles();
      if (files.isEmpty) {
        _emit(const CorpusDownloadProgress(state: CorpusInstallState.notInstalled));
        return;
      }
      await _verifyAndLoadLocalFiles(files);
    } catch (e, st) {
      Logger.error('[MessageCorpus] initIfEnabled failed: $e\n$st');
      _emit(CorpusDownloadProgress(
        state: CorpusInstallState.error,
        message: '대사 레코드 초기화 실패',
        error: e.toString(),
      ));
    }
  }

  Future<RemoteCorpusInfo?> checkRemoteInfo([String? customUrl]) async {
    final url = (customUrl ?? Settings.messageCorpusUrl.value).trim();
    if (url.isEmpty) return null;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        followRedirects: true,
      ));
      final headRes = await dio.head<void>(url);
      if (headRes.statusCode == 200) {
        final etag = headRes.headers.value('etag') ?? '';
        final lastMod = headRes.headers.value('last-modified') ?? '';
        final lenStr = headRes.headers.value('content-length') ?? '0';
        return RemoteCorpusInfo(
          url: url,
          versionTag: '${etag}_${lastMod}_$lenStr'.trim(),
          compressedBytes: int.tryParse(lenStr) ?? 0,
        );
      }
    } catch (_) {}
    return null;
  }

  Future<bool> enableAndDownload({String? customUrl, bool force = false}) async {
    if (isBusy) return false;
    if (customUrl != null && customUrl.trim().isNotEmpty) {
      await Settings.messageCorpusUrl.setValue(customUrl.trim());
    }

    final url = Settings.messageCorpusUrl.value.trim();
    _emit(const CorpusDownloadProgress(
      state: CorpusInstallState.checking,
      message: '원격 한국어 대사 레코드 확인 중...',
    ));

    try {
      final existing = await findInstalledFscmFiles();
      final remote = await checkRemoteInfo(url);

      if (!force &&
          existing.isNotEmpty &&
          (remote == null ||
              (remote.versionTag.isNotEmpty &&
                  remote.versionTag == Settings.messageCorpusVersion.value))) {
        final ok = await _verifyAndLoadLocalFiles(existing);
        if (ok) {
          await Settings.enableMessageSearch.setValue(true);
        }
        return ok;
      }

      final corpusDir = await getCorpusDir();
      final tmpArchive = File(p.join(corpusDir.path, 'corpus_download.tmp'));
      if (await tmpArchive.exists()) await tmpArchive.delete();

      _cancelToken = CancelToken();
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 20),
        followRedirects: true,
      ));

      int lastBytes = 0;
      DateTime lastTick = DateTime.now();
      double currentSpeed = 0;

      await dio.download(
        url,
        tmpArchive.path,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          final now = DateTime.now();
          final dtMs = now.difference(lastTick).inMilliseconds;
          if (dtMs >= 300) {
            currentSpeed = (received - lastBytes) * 1000.0 / dtMs;
            lastBytes = received;
            lastTick = now;
          }
          _emit(CorpusDownloadProgress(
            state: CorpusInstallState.downloading,
            receivedBytes: received,
            totalBytes: total > 0 ? total : (remote?.compressedBytes ?? 0),
            speedBytesPerSec: currentSpeed,
            message: '한국어 대사 레코드 다운로드 중...',
          ));
        },
      );
      _cancelToken = null;

      final ok = await installFromArchiveOrFscmFile(
        tmpArchive,
        isRawFscm: url.toLowerCase().split('?').first.endsWith('.fscm'),
        versionTag: remote?.versionTag ?? '',
        deleteSourceAfterInstall: true,
      );
      if (ok) {
        await Settings.enableMessageSearch.setValue(true);
      }
      return ok;
    } on DioException catch (e) {
      _cancelToken = null;
      if (CancelToken.isCancel(e)) {
        _emit(const CorpusDownloadProgress(
          state: CorpusInstallState.notInstalled,
          message: '다운로드가 취소되었습니다.',
        ));
        return false;
      }
      final friendly = formatDioError(e);
      Logger.error('[MessageCorpus] Download error: $friendly (${e.message})');
      _emit(CorpusDownloadProgress(
        state: CorpusInstallState.error,
        message: friendly,
        error: friendly,
      ));
      return false;
    } catch (e, st) {
      _cancelToken = null;
      Logger.error('[MessageCorpus] Install error: $e\n$st');
      _emit(CorpusDownloadProgress(
        state: CorpusInstallState.error,
        message: '설치 실패: $e',
        error: e.toString(),
      ));
      return false;
    }
  }

  @visibleForTesting
  static String formatDioError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 404) {
      return '대사 레코드 파일을 찾을 수 없습니다 (HTTP 404). 릴리스 업로드 여부를 확인하거나 로컬 파일(.7z/.fscm)을 불러와 주세요.';
    }
    if (code != null) {
      return '다운로드 실패 (HTTP $code). 네트워크 또는 주소를 확인해 주세요.';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '서버 응답 시간이 초과되었습니다. 네트워크 상태를 확인해 주세요.';
      case DioExceptionType.connectionError:
        return '네트워크에 연결할 수 없습니다.';
      default:
        return '다운로드 중 오류가 발생했습니다.';
    }
  }

  Future<bool> pickAndInstallLocalFile() async {
    if (isBusy) return false;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final filePath = picked?.files.single.path;
    if (filePath == null || filePath.isEmpty) return false;

    final file = File(filePath);
    if (!await file.exists()) return false;

    try {
      final isRaw = filePath.toLowerCase().endsWith('.fscm');
      final ok = await installFromArchiveOrFscmFile(
        file,
        isRawFscm: isRaw,
        versionTag: 'local_${await file.length()}',
        deleteSourceAfterInstall: false,
      );
      if (ok) {
        await Settings.enableMessageSearch.setValue(true);
      }
      return ok;
    } catch (e, st) {
      Logger.error('[MessageCorpus] Local install error: $e\n$st');
      _emit(CorpusDownloadProgress(
        state: CorpusInstallState.error,
        message: '로컬 파일 설치 실패: $e',
        error: e.toString(),
      ));
      return false;
    }
  }

  /// 로컬에 다운로드된 `.7z` 또는 `.fscm` 파일을 검증·추출 후 엔진에 마운트합니다.
  Future<bool> installFromArchiveOrFscmFile(
    File sourceFile, {
    bool isRawFscm = false,
    String versionTag = '',
    bool deleteSourceAfterInstall = false,
  }) async {
    final corpusDir = await getCorpusDir();
    final stagingDir = Directory(p.join(corpusDir.path, '_staging'));
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    await stagingDir.create(recursive: true);

    try {
      if (isRawFscm) {
        final dst = File(p.join(stagingDir.path, 'merged-ko.fscm'));
        await sourceFile.copy(dst.path);
      } else {
        _emit(const CorpusDownloadProgress(
          state: CorpusInstallState.extracting,
          message: '한국어 대사 레코드 압축 해제 중...',
        ));
        await rust_simple.decompress7ZFlat(
          src: sourceFile.path,
          destDir: stagingDir.path,
        );
      }

      if (deleteSourceAfterInstall && await sourceFile.exists()) {
        await sourceFile.delete();
      }

      final stagedFscm = await stagingDir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.fscm'))
          .cast<File>()
          .toList();
      if (stagedFscm.isEmpty) {
        throw Exception('압축 파일 내부에 .fscm 대사 레코드가 없습니다.');
      }

      for (final f in stagedFscm) {
        await rust_msg.verifyFscmFile(path: f.path);
      }

      rust_msg.mobileSearchUnload();

      for (final old in await findInstalledFscmFiles()) {
        if (await old.exists()) await old.delete();
      }
      final installedFiles = <File>[];
      for (final f in stagedFscm) {
        final dstPath = p.join(corpusDir.path, p.basename(f.path));
        final moved = await f.rename(dstPath);
        installedFiles.add(moved);
      }
      if (await stagingDir.exists()) await stagingDir.delete(recursive: true);

      final ok = await _verifyAndLoadLocalFiles(installedFiles);
      if (ok) {
        if (versionTag.isNotEmpty) {
          await Settings.messageCorpusVersion.setValue(versionTag);
        }
        await Settings.lastMessageCorpusSyncTime.setValue(
          DateTime.now().toIso8601String(),
        );
      }
      return ok;
    } catch (e) {
      if (await stagingDir.exists()) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  void cancelDownload() {
    _cancelToken?.cancel('사용자 취소');
    _cancelToken = null;
  }

  Future<void> disable({required bool deleteFiles}) async {
    cancelDownload();
    rust_msg.mobileSearchUnload();
    await Settings.enableMessageSearch.setValue(false);
    await Settings.inViewerMessageSearch.setValue(false);
    if (deleteFiles) {
      await deleteCorpusFiles();
    } else {
      _emit(const CorpusDownloadProgress(state: CorpusInstallState.notInstalled));
    }
  }

  Future<void> deleteCorpusFiles() async {
    rust_msg.mobileSearchUnload();
    final files = await findInstalledFscmFiles();
    for (final f in files) {
      if (await f.exists()) await f.delete();
    }
    _recordCount = 0;
    _localBytes = 0;
    _maxArticleId = 0;
    await Settings.messageCorpusVersion.setValue('');
    _emit(const CorpusDownloadProgress(state: CorpusInstallState.notInstalled));
  }

  /// 검색 DSL(예: "artist:nishi female:elf page>30")에 매칭되는 한국어 작품 ID 화이트리스트 조회
  Future<List<int>?> resolveArticleWhitelist(String articleCondition) async {
    final trimmed = articleCondition.trim();
    if (trimmed.isEmpty) return null;
    final fullSql = translate2query('$trimmed lang:korean');
    final selectIdSql = fullSql.replaceFirst(
      'SELECT * FROM HitomiColumnModel',
      'SELECT Id FROM HitomiColumnModel',
    );
    final db = await DataBaseManager.getInstance();
    final rows = await db.query(selectIdSql);
    return rows
        .map((r) => (r['Id'] as num?)?.toInt())
        .whereType<int>()
        .where((id) => id >= 0)
        .toList();
  }

  rust_msg.MobileSearchProgress get progressSnapshot =>
      rust_msg.mobileSearchProgress();

  bool cancelActiveSearch() => rust_msg.mobileSearchCancel();

  bool _popularSynced = false;

  Future<void> ensurePopularRanksSynced() async {
    if (_popularSynced) return;
    await Population.ensureLoaded();
    final pop = Population.population;
    if (pop.isEmpty) return;
    final entries = pop.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final ids = Uint32List(entries.length);
    for (var i = 0; i < entries.length; i++) {
      ids[i] = entries[i].key;
    }
    rust_msg.mobileSearchSetPopularIds(ids: ids);
    _popularSynced = true;
  }

  Future<rust_msg.MobileSearchResponse> searchGlobalEx({
    required String query,
    DialogueSearchMode mode = DialogueSearchMode.contains,
    DialogueSortMode sortMode = DialogueSortMode.relevance,
    int take = 500,
    List<int>? whitelistIds,
    int? idMin,
    int? idMax,
  }) async {
    if (!isReady) {
      throw StateError('한국어 대사 레코드가 활성화되지 않았습니다.');
    }
    await ensurePopularRanksSynced();
    final filter = rust_msg.MobileSearchFilter(
      idMin: idMin,
      idMax: idMax,
      whitelistIds: whitelistIds != null
          ? Uint32List.fromList(whitelistIds)
          : null,
      sortMode: sortMode.index,
    );
    return await rust_msg.mobileSearchQueryEx(
      query: query,
      containsMode: mode == DialogueSearchMode.contains,
      take: take,
      filter: filter,
    );
  }

  Future<List<rust_msg.MobileMessageHit>> searchGlobal({
    required String query,
    DialogueSearchMode mode = DialogueSearchMode.contains,
    DialogueSortMode sortMode = DialogueSortMode.relevance,
    int take = 500,
    List<int>? whitelistIds,
    int? idMin,
    int? idMax,
  }) async {
    final res = await searchGlobalEx(
      query: query,
      mode: mode,
      sortMode: sortMode,
      take: take,
      whitelistIds: whitelistIds,
      idMin: idMin,
      idMax: idMax,
    );
    return res.hits;
  }

  Future<List<rust_msg.MobileMessageHit>> searchInArticle(
    int articleId,
    String query,
  ) async {
    if (!isReady) return const [];
    return await rust_msg.mobileSearchArticle(
      articleId: articleId,
      query: query,
    );
  }
}