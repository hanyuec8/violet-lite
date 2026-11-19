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
import 'package:violet/component/hangul_auto_restorer.dart';
import 'package:violet/component/hitomi/hitomi_nozomi.dart';
import 'package:violet/component/hitomi/population.dart';
import 'package:violet/component/hitomi/tag_translate.dart';
import 'package:violet/component/query_translate.dart';
import 'package:violet/database/database.dart';
import 'package:violet/database/expunged_database.dart';
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

class ArticleFilterResolution {
  /// null이면 전체 한국어 코퍼스 허용, 빈 리스트면 조건 일치 작품 0건
  final List<int>? whitelistIds;
  final int? idMin;
  final int? idMax;
  final Set<int> excludedIds;

  /// 로컬 DB가 비어있을 때 메타데이터 조회 후 사후 필터링할 조건 (예: page>30, date>=2024)
  final String? postFilterCondition;

  /// 단독 DB 전용 조건 등으로 필터링 자체가 불가능한 경우 안내 메시지
  final String? errorMessage;

  const ArticleFilterResolution({
    this.whitelistIds,
    this.idMin,
    this.idMax,
    this.excludedIds = const <int>{},
    this.postFilterCondition,
    this.errorMessage,
  });

  bool get isEmptyMatch => whitelistIds != null && whitelistIds!.isEmpty;
}

abstract class _NozomiExprNode {
  const _NozomiExprNode();
}

class _UniverseNode extends _NozomiExprNode {
  const _UniverseNode();
  static const instance = _UniverseNode();
}

class _SetNode extends _NozomiExprNode {
  final Set<int> ids;
  _SetNode(this.ids);
}

class _NegatedSetNode extends _NozomiExprNode {
  final Set<int> excluded;
  _NegatedSetNode(this.excluded);
}

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
  bool _engineMounted = false;
  CancelToken? _cancelToken;

  CorpusInstallState get state => _state;
  CorpusDownloadProgress get progress => _progress;
  int get recordCount => _recordCount;
  int get localBytes => _localBytes;
  int get maxArticleId => _maxArticleId;
  bool get isReady =>
      Settings.enableMessageSearch.value &&
      (_state == CorpusInstallState.ready || _engineMounted);
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
    _engineMounted = true;
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
      _engineMounted = false;
      _state = CorpusInstallState.notInstalled;
      notifyListeners();
      return;
    }
    if (isBusy || _engineMounted) return;
    try {
      final files = await findInstalledFscmFiles();
      if (files.isEmpty) {
        _engineMounted = false;
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

      _engineMounted = false;
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
    _engineMounted = false;
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
    _engineMounted = false;
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

  @visibleForTesting
  bool testForceEmptyLocalDb = false;

  static final RegExp _hangulRegex = RegExp(r'[가-힣ㄱ-ㅎㅏ-ㅣ]');

  static List<String> _tokenizeCondition(String input) {
    final result = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == ' ' || ch == '\t' || ch == '\n') {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
      } else if (ch == '(' || ch == ')') {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
        result.add(ch);
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) {
      result.add(buf.toString());
    }
    return result;
  }

  static String _normalizeLangValue(String raw) {
    final l = raw.trim().toLowerCase();
    if (l == 'ko' || l == 'korea' || l == 'korean' || l == '한국어') {
      return 'korean';
    }
    if (l == 'ja' || l == 'jp' || l == 'japan' || l == 'japanese' || l == '일본어') {
      return 'japanese';
    }
    if (l == 'en' || l == 'english' || l == '영어') return 'english';
    if (l == 'zh' || l == 'cn' || l == 'chinese' || l == '중국어') {
      return 'chinese';
    }
    if (l == 'all' || l == '전체') return 'all';
    return l;
  }

  static bool _isDbOnlyFilterToken(String rawCore) {
    final lower = rawCore.toLowerCase();
    if (RegExp(r'^page(?:>=|<=|==|>|<|=|:)').hasMatch(lower)) return true;
    if (RegExp(r'^(?:date|published)(?:>=|<=|==|>|<|=|:)').hasMatch(lower)) {
      return true;
    }
    if (lower.startsWith('class:')) return true;
    return false;
  }

  static List<String> _resolveKoreanTagNames(String rawVal, {String? group}) {
    final restored = Settings.enableHangulTypoRestore.value
        ? (HangulAutoRestorer.tryRestoreKoreanWord(rawVal) ?? rawVal)
        : rawVal;
    final cleanTarget = restored.trim().toLowerCase().replaceAll(' ', '');
    if (cleanTarget.isEmpty) return const [];

    final matches = TagTranslate.containsTotal(restored).where((tag) {
      if (group == null) return true;
      if (group == 'tag') {
        return tag.group == 'tag' ||
            tag.group == 'female' ||
            tag.group == 'male';
      }
      return tag.group == group;
    }).toList();

    if (matches.isEmpty) return const [];

    final exactMatches = matches.where((tag) {
      final trans = (tag.translated ?? '').toLowerCase();
      return trans.split('|').any(
            (part) => part.trim().replaceAll(' ', '') == cleanTarget,
          );
    }).toList();

    final picked = (exactMatches.isNotEmpty ? exactMatches : matches).take(3);
    return picked
        .map((t) => t.getTag())
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  Future<Set<int>> _fetchNozomiForTerm(
    String rawCore,
    String effectiveLang, {
    required bool throwOnError,
  }) async {
    Future<Set<int>> fetchSingleUrl(String url) async {
      final ids = await HitomiNozomi.fetchAllGalleryIds(
        url,
        throwOnError: throwOnError,
      );
      return ids.toSet();
    }

    Future<Set<int>> fetchTagUrls(String group, String val) async {
      if (_hangulRegex.hasMatch(val)) {
        final resolvedTags = _resolveKoreanTagNames(val, group: group);
        if (resolvedTags.isNotEmpty) {
          final sets = await Future.wait(
            resolvedTags.map(
              (t) => fetchSingleUrl(
                HitomiNozomi.getTagIndexUrl(t, effectiveLang),
              ),
            ),
          );
          return sets.expand((e) => e).toSet();
        }
      }
      if (group == 'tag') {
        final tagSets = await Future.wait([
          fetchSingleUrl(HitomiNozomi.getTagIndexUrl(val, effectiveLang)),
          fetchSingleUrl(
            HitomiNozomi.getTagIndexUrl('female:$val', effectiveLang),
          ),
          fetchSingleUrl(
            HitomiNozomi.getTagIndexUrl('male:$val', effectiveLang),
          ),
        ]);
        return tagSets.expand((e) => e).toSet();
      }
      return await fetchSingleUrl(
        HitomiNozomi.getTagIndexUrl('$group:$val', effectiveLang),
      );
    }

    final colonIdx = rawCore.indexOf(':');
    if (colonIdx > 0) {
      final prefix = rawCore.substring(0, colonIdx).trim().toLowerCase();
      final val = rawCore.substring(colonIdx + 1).trim();
      if (val.isEmpty) return <int>{};

      switch (prefix) {
        case 'female':
        case 'male':
        case 'tag':
          return await fetchTagUrls(prefix, val);
        case 'artist':
          return await fetchSingleUrl(
            HitomiNozomi.getArtistIndexUrl(val, effectiveLang),
          );
        case 'group':
          return await fetchSingleUrl(
            HitomiNozomi.getGroupIndexUrl(val, effectiveLang),
          );
        case 'series':
        case 'character':
          final isSeries = prefix == 'series';
          if (_hangulRegex.hasMatch(val)) {
            final resolved = _resolveKoreanTagNames(val, group: prefix);
            if (resolved.isNotEmpty) {
              final sets = await Future.wait(
                resolved.map((t) {
                  final name = t.split(':').last;
                  return fetchSingleUrl(
                    isSeries
                        ? HitomiNozomi.getSeriesIndexUrl(name, effectiveLang)
                        : HitomiNozomi.getCharacterIndexUrl(
                            name,
                            effectiveLang,
                          ),
                  );
                }),
              );
              return sets.expand((e) => e).toSet();
            }
          }
          return await fetchSingleUrl(
            isSeries
                ? HitomiNozomi.getSeriesIndexUrl(val, effectiveLang)
                : HitomiNozomi.getCharacterIndexUrl(val, effectiveLang),
          );
        case 'uploader':
          return await fetchSingleUrl(
            HitomiNozomi.getUploaderIndexUrl(val, effectiveLang),
          );
        case 'type':
          return await fetchSingleUrl(
            HitomiNozomi.getTypeIndexUrl(val, effectiveLang),
          );
        case 'lang':
        case 'language':
          final normLang = _normalizeLangValue(val);
          if (normLang == 'korean') return <int>{};
          return await fetchSingleUrl(
            HitomiNozomi.getLanguageIndexUrl(normLang),
          );
      }
    }

    final restoredKor = Settings.enableHangulTypoRestore.value
        ? HangulAutoRestorer.tryRestoreKoreanWord(rawCore)
        : null;
    if (_hangulRegex.hasMatch(rawCore) || restoredKor != null) {
      final resolvedTags = _resolveKoreanTagNames(restoredKor ?? rawCore);
      if (resolvedTags.isNotEmpty) {
        final urls = <String>[];
        for (final t in resolvedTags) {
          final idx = t.indexOf(':');
          if (idx <= 0) continue;
          final g = t.substring(0, idx);
          final n = t.substring(idx + 1);
          if (g == 'female' || g == 'male' || g == 'tag') {
            urls.add(HitomiNozomi.getTagIndexUrl(t, effectiveLang));
          } else if (g == 'series') {
            urls.add(HitomiNozomi.getSeriesIndexUrl(n, effectiveLang));
          } else if (g == 'character') {
            urls.add(HitomiNozomi.getCharacterIndexUrl(n, effectiveLang));
          }
        }
        if (urls.isNotEmpty) {
          final sets = await Future.wait(urls.map(fetchSingleUrl));
          return sets.expand((e) => e).toSet();
        }
      }
    }

    final fallbackSets = await Future.wait([
      fetchSingleUrl(HitomiNozomi.getTagIndexUrl('female:$rawCore', effectiveLang)),
      fetchSingleUrl(HitomiNozomi.getTagIndexUrl('male:$rawCore', effectiveLang)),
      fetchSingleUrl(HitomiNozomi.getTagIndexUrl(rawCore, effectiveLang)),
      fetchSingleUrl(HitomiNozomi.getArtistIndexUrl(rawCore, effectiveLang)),
      fetchSingleUrl(HitomiNozomi.getSeriesIndexUrl(rawCore, effectiveLang)),
    ]);
    return fallbackSets.expand((e) => e).toSet();
  }
  /// 검색 DSL(예: "artist:nishi female:elf page>30")을 해석하여
  /// 로컬 SQLite DB 및 Hitomi Nozomi 하이브리드 작품 ID 필터를 생성합니다.
  Future<ArticleFilterResolution> resolveArticleFilter(
    String articleCondition,
  ) async {
    final trimmed = articleCondition.trim();
    if (trimmed.isEmpty) return const ArticleFilterResolution();

    final normalized = Settings.enableHangulTypoRestore.value
        ? HangulAutoRestorer.normalizeQuery(trimmed)
        : trimmed;
    final tokens = _tokenizeCondition(normalized);
    if (tokens.isEmpty) return const ArticleFilterResolution();

    // 1. 로컬 SQLite DB(HitomiColumnModel) 데이터 유무 확인
    bool hasLocalMainDb = false;
    DataBaseManager? mainDb;
    if (!testForceEmptyLocalDb) {
      try {
        mainDb = await DataBaseManager.getInstance();
        if (mainDb.db != null && mainDb.db!.isOpen) {
          final probe = await mainDb.query(
            'SELECT 1 FROM HitomiColumnModel LIMIT 1',
          );
          hasLocalMainDb = probe.isNotEmpty;
        }
      } catch (_) {}
    }

    // 2. 언어 및 DB 전용 사후 필터 토큰 / ID 범위 스캔
    String effectiveLang = 'korean';
    bool hasExplicitNonKoreanLang = false;
    int? idMin;
    int? idMax;
    final excludedIds = <int>{};
    final postFilterTokens = <String>[];
    bool hasDbOnlyTokens = false;
    bool hasNozomiOrIdTokens = false;

    for (final raw in tokens) {
      if (raw == '(' || raw == ')' || raw.toLowerCase() == 'or') continue;
      final negative = raw.startsWith('-') && raw.length > 1;
      final core = negative ? raw.substring(1) : raw;
      final lower = core.toLowerCase();

      if (lower.startsWith('lang:') || lower.startsWith('language:')) {
        final v = _normalizeLangValue(lower.split(':').last);
        effectiveLang = v;
        if (v != 'korean') hasExplicitNonKoreanLang = true;
        continue;
      }

      if (_isDbOnlyFilterToken(core)) {
        hasDbOnlyTokens = true;
        postFilterTokens.add(raw);
        continue;
      }

      if (int.tryParse(core) != null) {
        final v = int.parse(core);
        if (v > 0) {
          hasNozomiOrIdTokens = true;
          if (negative) {
            excludedIds.add(v);
          } else {
            idMin = idMin == null ? v : (v > idMin ? v : idMin);
            idMax = idMax == null ? v : (v < idMax ? v : idMax);
          }
          continue;
        }
      }

      final idRange = RegExp(
        r'^id:(\d+)(?:~|\.\.|\-)(\d+)$',
        caseSensitive: false,
      ).firstMatch(core);
      if (idRange != null && !negative) {
        final a = int.parse(idRange.group(1)!);
        final b = int.parse(idRange.group(2)!);
        final lo = a <= b ? a : b;
        final hi = a <= b ? b : a;
        hasNozomiOrIdTokens = true;
        idMin = idMin == null ? lo : (lo > idMin ? lo : idMin);
        idMax = idMax == null ? hi : (hi < idMax ? hi : idMax);
        continue;
      }

      final idOp = RegExp(
        r'^id(!=|>=|<=|==|>|<|=|:)(\d+)$',
        caseSensitive: false,
      ).firstMatch(core);
      if (idOp != null) {
        final op = idOp.group(1)!;
        final v = int.parse(idOp.group(2)!);
        hasNozomiOrIdTokens = true;
        if (op == '!=') {
          if (!negative) excludedIds.add(v);
        } else if (op == ':' || op == '=' || op == '==') {
          if (negative) {
            excludedIds.add(v);
          } else {
            idMin = idMin == null ? v : (v > idMin ? v : idMin);
            idMax = idMax == null ? v : (v < idMax ? v : idMax);
          }
        } else if (!negative) {
          if (op == '>=') idMin = idMin == null ? v : (v > idMin ? v : idMin);
          if (op == '>') {
            idMin = idMin == null ? v + 1 : (v + 1 > idMin ? v + 1 : idMin);
          }
          if (op == '<=') idMax = idMax == null ? v : (v < idMax ? v : idMax);
          if (op == '<') {
            idMax = idMax == null ? v - 1 : (v - 1 < idMax ? v - 1 : idMax);
          }
        }
        continue;
      }

      hasNozomiOrIdTokens = true;
    }

    if (idMin != null && idMax != null && idMin > idMax) {
      return const ArticleFilterResolution(whitelistIds: <int>[]);
    }

    if (!hasLocalMainDb && hasDbOnlyTokens && !hasNozomiOrIdTokens) {
      return const ArticleFilterResolution(
        errorMessage:
            '로컬 작품 DB가 없어 페이지·날짜·분류 단독 조건은 필터링할 수 없습니다.\n'
            'female:, male:, tag:, artist: 등 태그 조건과 함께 사용해 주세요.',
      );
    }

    // 4. 로컬 DB 쿼리 실행 (DB가 채워져 있을 때)
    Set<int>? dbIds;
    if (hasLocalMainDb && mainDb != null) {
      final sqlTokens = tokens.map((tok) {
        final neg = tok.startsWith('-') && tok.length > 1;
        final core = neg ? tok.substring(1) : tok;
        if (int.tryParse(core) != null) {
          return neg ? '-id:$core' : 'id:$core';
        }
        return tok;
      }).join(' ');
      final hasLangTok = tokens.any((t) {
        final c =
            t.startsWith('-') ? t.substring(1).toLowerCase() : t.toLowerCase();
        return c.startsWith('lang:') || c.startsWith('language:');
      });
      final queryForSql = hasLangTok ? sqlTokens : '$sqlTokens lang:korean';
      final fullSql = translate2query(queryForSql);
      final selectIdSql = fullSql.replaceFirst(
        'SELECT * FROM HitomiColumnModel',
        'SELECT Id FROM HitomiColumnModel',
      );
      final rows = await mainDb.query(selectIdSql);
      dbIds = rows
          .map((r) => (r['Id'] as num?)?.toInt())
          .whereType<int>()
          .where((id) => id >= 0)
          .toSet();

      try {
        final expDb = await ExpungedDatabaseManager.getInstance();
        if (expDb != null && expDb.isOpen) {
          final expRows = await expDb.rawQuery(selectIdSql);
          for (final r in expRows) {
            final id = (r['Id'] as num?)?.toInt();
            if (id != null && id >= 0) dbIds.add(id);
          }
        }
      } catch (_) {}

      if (hasDbOnlyTokens) {
        return ArticleFilterResolution(whitelistIds: dbIds.toList());
      }
    }

    // 5. Hitomi Nozomi 불리언 식 평가 (경량 DB 미보유 환경 핵심 경로 + 하이브리드 병합)
    final hasOr = tokens.any((t) => t.toLowerCase() == 'or');
    final needsNozomiScan = hasExplicitNonKoreanLang ||
        tokens.any((raw) {
          if (raw == '(' || raw == ')' || raw.toLowerCase() == 'or') {
            return false;
          }
          final neg = raw.startsWith('-') && raw.length > 1;
          final core = neg ? raw.substring(1) : raw;
          final lower = core.toLowerCase();
          if (lower.startsWith('lang:') || lower.startsWith('language:')) {
            return false;
          }
          if (_isDbOnlyFilterToken(core)) return false;
          if (int.tryParse(core) != null) return false;
          if (RegExp(
            r'^id(?:!=|>=|<=|==|>|<|=|:)',
            caseSensitive: false,
          ).hasMatch(core)) {
            return false;
          }
          return true;
        });

    Set<int>? nozomiIds;
    if (needsNozomiScan || hasOr) {
      final evaluated = await _evaluateNozomiExpression(
        tokens,
        effectiveLang,
        throwOnError: !hasLocalMainDb,
      );
      if (evaluated is _SetNode) {
        nozomiIds = evaluated.ids;
      } else if (evaluated is _NegatedSetNode) {
        final universe = await HitomiNozomi.fetchAllGalleryIds(
          HitomiNozomi.getLanguageIndexUrl(effectiveLang),
          throwOnError: !hasLocalMainDb,
        );
        nozomiIds =
            universe.where((id) => !evaluated.excluded.contains(id)).toSet();
      }
    }

    // 6. 결과 병합 및 범위/제외 적용
    Set<int>? combined;
    if (dbIds != null && nozomiIds != null) {
      combined = <int>{...dbIds, ...nozomiIds};
    } else if (nozomiIds != null) {
      combined = nozomiIds;
    } else if (dbIds != null) {
      combined = dbIds;
    }

    if (combined != null) {
      combined.removeWhere(
        (id) =>
            excludedIds.contains(id) ||
            (idMin != null && id < idMin) ||
            (idMax != null && id > idMax),
      );
      return ArticleFilterResolution(
        whitelistIds: combined.toList(),
        idMin: idMin,
        idMax: idMax,
        excludedIds: excludedIds,
        postFilterCondition:
            postFilterTokens.isNotEmpty ? postFilterTokens.join(' ') : null,
      );
    }

    return ArticleFilterResolution(
      whitelistIds: null,
      idMin: idMin,
      idMax: idMax,
      excludedIds: excludedIds,
      postFilterCondition:
          postFilterTokens.isNotEmpty ? postFilterTokens.join(' ') : null,
    );
  }

  Future<_NozomiExprNode> _evaluateNozomiExpression(
    List<String> tokens,
    String effectiveLang, {
    required bool throwOnError,
  }) async {
    var cursor = 0;

    Future<_NozomiExprNode> materialize(_NozomiExprNode node) async {
      if (node is _NegatedSetNode) {
        final universe = await HitomiNozomi.fetchAllGalleryIds(
          HitomiNozomi.getLanguageIndexUrl(effectiveLang),
          throwOnError: throwOnError,
        );
        return _SetNode(
          universe.where((id) => !node.excluded.contains(id)).toSet(),
        );
      }
      return node;
    }

    Future<_NozomiExprNode> combineAnd(
      _NozomiExprNode left,
      _NozomiExprNode right,
    ) async {
      if (left is _UniverseNode) return right;
      if (right is _UniverseNode) return left;
      if (left is _SetNode && right is _SetNode) {
        return _SetNode(left.ids.intersection(right.ids));
      }
      if (left is _SetNode && right is _NegatedSetNode) {
        return _SetNode(left.ids.difference(right.excluded));
      }
      if (left is _NegatedSetNode && right is _SetNode) {
        return _SetNode(right.ids.difference(left.excluded));
      }
      if (left is _NegatedSetNode && right is _NegatedSetNode) {
        return _NegatedSetNode(<int>{...left.excluded, ...right.excluded});
      }
      return left;
    }

    Future<_NozomiExprNode> combineOr(
      _NozomiExprNode left,
      _NozomiExprNode right,
    ) async {
      if (left is _UniverseNode || right is _UniverseNode) {
        return _UniverseNode.instance;
      }
      final ml = await materialize(left);
      final mr = await materialize(right);
      if (ml is _SetNode && mr is _SetNode) {
        return _SetNode(<int>{...ml.ids, ...mr.ids});
      }
      return _UniverseNode.instance;
    }

    late Future<_NozomiExprNode> Function() parseOr;

    Future<_NozomiExprNode> parseAtom() async {
      if (cursor >= tokens.length) return _UniverseNode.instance;
      final tok = tokens[cursor++];

      if (tok == '(') {
        final inner = await parseOr();
        if (cursor < tokens.length && tokens[cursor] == ')') {
          cursor++;
        }
        return inner;
      }
      if (tok == ')') {
        return _UniverseNode.instance;
      }

      final negative = tok.startsWith('-') && tok.length > 1;
      final core = negative ? tok.substring(1) : tok;
      final lower = core.toLowerCase();

      if (_isDbOnlyFilterToken(core)) {
        return _UniverseNode.instance;
      }
      if (lower.startsWith('lang:') || lower.startsWith('language:')) {
        final v = _normalizeLangValue(lower.split(':').last);
        if (v == 'korean' && !negative) return _UniverseNode.instance;
        final ids = await _fetchNozomiForTerm(
          core,
          effectiveLang,
          throwOnError: throwOnError,
        );
        return negative ? _NegatedSetNode(ids) : _SetNode(ids);
      }

      if (int.tryParse(core) != null) {
        final v = int.parse(core);
        return negative ? _NegatedSetNode({v}) : _SetNode({v});
      }
      final idEq = RegExp(
        r'^id(?:==|=|:)(\d+)$',
        caseSensitive: false,
      ).firstMatch(core);
      if (idEq != null) {
        final v = int.parse(idEq.group(1)!);
        return negative ? _NegatedSetNode({v}) : _SetNode({v});
      }
      if (RegExp(
        r'^id(?:!=|>=|<=|==|>|<|=|:)',
        caseSensitive: false,
      ).hasMatch(core)) {
        return _UniverseNode.instance;
      }

      final ids = await _fetchNozomiForTerm(
        core,
        effectiveLang,
        throwOnError: throwOnError,
      );
      return negative ? _NegatedSetNode(ids) : _SetNode(ids);
    }

    Future<_NozomiExprNode> parseAnd() async {
      var left = await parseAtom();
      while (cursor < tokens.length) {
        final next = tokens[cursor];
        if (next == ')' || next.toLowerCase() == 'or') break;
        final right = await parseAtom();
        left = await combineAnd(left, right);
      }
      return left;
    }

    parseOr = () async {
      var left = await parseAnd();
      while (cursor < tokens.length && tokens[cursor].toLowerCase() == 'or') {
        cursor++;
        final right = await parseAnd();
        left = await combineOr(left, right);
      }
      return left;
    };

    return await parseOr();
  }

  /// 검색 DSL(예: "artist:nishi female:elf page>30")에 매칭되는 한국어 작품 ID 화이트리스트 조회
  Future<List<int>?> resolveArticleWhitelist(String articleCondition) async {
    final res = await resolveArticleFilter(articleCondition);
    if (res.errorMessage != null) return <int>[];
    if (res.whitelistIds != null) return res.whitelistIds;
    if (res.idMin != null && res.idMax != null && res.idMin == res.idMax) {
      return <int>[res.idMin!];
    }
    return null;
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