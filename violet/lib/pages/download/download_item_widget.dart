// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/other/dialogs.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/common/utils.dart';
import 'package:violet/pages/download/download_routine.dart';
import 'package:violet/pages/viewer/viewer_page.dart';
import 'package:violet/pages/viewer/viewer_page_provider.dart';
import 'package:violet/settings/settings.dart';

enum DownloadBatchAction { resume, stop }

class DownloadItemWidget extends StatefulWidget {
  final DownloadItemModel item;
  final VoidCallback onChanged;
  final Future<void> Function(DownloadItemModel item) onDelete;
  final DownloadResultType viewType;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onEnterSelectionMode;
  final Stream<(int, DownloadBatchAction)>? batchActionStream;

  const DownloadItemWidget({
    super.key,
    required this.item,
    required this.onChanged,
    required this.onDelete,
    required this.viewType,
    this.selectionMode = false,
    this.isSelected = false,
    this.onToggleSelect,
    this.onEnterSelectionMode,
    this.batchActionStream,
  });

  @override
  State<DownloadItemWidget> createState() => _DownloadItemWidgetState();
}

class _DownloadItemWidgetState extends State<DownloadItemWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive =>
      widget.item.state() == 1 ||
      widget.item.state() == 2 ||
      widget.item.state() == 3;

  late DownloadRoutine _routine;
  int _extractCurrent = 0;
  int _extractTotal = 0;
  int _downloadDone = 0;
  int _downloadTotal = 0;
  int _downloadErrors = 0;
  double _downloadedBytes = 0;
  bool _isRunning = false;
  bool _stopRequested = false;
  StreamSubscription<(int, DownloadBatchAction)>? _batchSub;
  final Set<String> _failedLocalFiles = <String>{};
  bool _thumbRefreshAttempted = false;
  bool _refreshingThumb = false;
  int _remoteRetryCount = 0;

  @override
  void initState() {
    super.initState();
    _routine = DownloadRoutine(
      widget.item,
      _safeSetState,
      _safeSetState,
    );
    _subscribeBatchActions();

    if (widget.item.state() == 1 && !widget.item.download) {
      unawaited(_startDownload(skipExisting: false));
    } else if (widget.item.state() == 2 || widget.item.state() == 3) {
      // 앱 강제 종료 등으로 중단된 작업을 중지 상태로 정리
      unawaited(_routine.setToStop());
    }
  }

  @override
  void didUpdateWidget(covariant DownloadItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.id() != oldWidget.item.id()) {
      _failedLocalFiles.clear();
      _thumbRefreshAttempted = false;
      _refreshingThumb = false;
      _remoteRetryCount = 0;
    }
    if (widget.batchActionStream != oldWidget.batchActionStream) {
      _batchSub?.cancel();
      _subscribeBatchActions();
    }
  }

  @override
  void dispose() {
    _batchSub?.cancel();
    super.dispose();
  }

  void _subscribeBatchActions() {
    _batchSub = widget.batchActionStream?.listen((event) {
      final (itemId, action) = event;
      if (!mounted || itemId != widget.item.id()) return;
      switch (action) {
        case DownloadBatchAction.resume:
          if (!_isRunning && widget.item.state() != 0) {
            unawaited(_startDownload(skipExisting: true));
          }
          break;
        case DownloadBatchAction.stop:
          if (_isRunning) {
            unawaited(_stopDownload());
          }
          break;
      }
    });
  }

  void _safeSetState() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _startDownload({required bool skipExisting}) async {
    if (_isRunning) return;
    _isRunning = true;
    _stopRequested = false;
    widget.item.download = true;
    _extractCurrent = 0;
    _extractTotal = 0;
    _downloadDone = 0;
    _downloadTotal = 0;
    _downloadErrors = 0;
    _downloadedBytes = 0;

    try {
      await _routine.selectExtractor();
      await _routine.createTasks(
        progressCallback: (cur, total) async {
          _extractCurrent = cur;
          _extractTotal = total;
          _safeSetState();
        },
      );

      if (_stopRequested) {
        await _routine.setToStop();
        return;
      }

      if (widget.item.state() == 7 || widget.item.state() == 11) {
        return;
      }

      if (await _routine.checkNothingToDownload()) {
        return;
      }

      await _routine.extractFilePath();

      final totalTasks = _routine.tasks!.length;
      _downloadTotal = totalTasks;
      _downloadDone = 0;
      _downloadErrors = 0;
      _safeSetState();

      final completer = Completer<void>();

      void checkDone() {
        if (_downloadDone + _downloadErrors >= _downloadTotal) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      }

      final queuedCount = await _routine.appendDownloadTasks(
        skipExistingValidFiles: skipExisting,
        completeCallback: () {
          _downloadDone++;
          _safeSetState();
          checkDone();
        },
        downloadCallback: (bytes) {
          _downloadedBytes += bytes;
          _safeSetState();
        },
        errorCallback: (err) {
          _downloadErrors++;
          _safeSetState();
          checkDone();
        },
      );

      if (queuedCount == 0) {
        if (!completer.isCompleted) completer.complete();
      }

      await completer.future;

      if (_stopRequested) {
        await _routine.setToStop();
        return;
      }

      // 누락/손상 파일 1회 검증 및 재시도
      final invalid = await _routine.checkDownloadFiles();
      if (invalid.isNotEmpty && !_stopRequested) {
        final retryCompleter = Completer<void>();
        int retryDone = 0;
        int retryErr = 0;
        void checkRetry() {
          if (retryDone + retryErr >= invalid.length) {
            if (!retryCompleter.isCompleted) retryCompleter.complete();
          }
        }

        await _routine.retryInvalidDownloadFiles(
          invalid,
          completeCallback: () {
            retryDone++;
            _downloadDone = (_downloadTotal - invalid.length) + retryDone;
            _safeSetState();
            checkRetry();
          },
          downloadCallback: (bytes) {
            _downloadedBytes += bytes;
            _safeSetState();
          },
          errorCallback: (err) {
            retryErr++;
            _safeSetState();
            checkRetry();
          },
        );
        await retryCompleter.future;
      }

      if (_stopRequested) {
        await _routine.setToStop();
        return;
      }

      final stillInvalid = await _routine.checkDownloadFiles();
      if (stillInvalid.isEmpty) {
        await _routine.setDownloadComplete();
      } else {
        _routine.result['ErrorMsg'] =
            '${stillInvalid.length}개 페이지 다운로드 실패';
        await _routine.setToStop();
      }
    } catch (e) {
      _routine.result['ErrorMsg'] = e.toString();
      await _routine.setToStop();
    } finally {
      _isRunning = false;
      widget.item.download = false;
      _safeSetState();
      widget.onChanged();
    }
  }

  Future<void> _stopDownload() async {
    _stopRequested = true;
    _routine.cancelActiveTasks();
    await _routine.setToStop();
    _safeSetState();
    widget.onChanged();
  }

  Future<void> _copyArticleId() async {
    final articleId = widget.item.url().trim();
    if (articleId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: articleId));
    showToast(
      icon: Icons.copy,
      level: ToastLevel.check,
      message: '작품 번호 $articleId 복사되었습니다.',
    );
  }

  Future<void> _openOfflineViewer() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final files = widget.item
        .filesWithoutThumbnail()
        .where((p) => File(p).existsSync())
        .toList();

    if (files.isEmpty) {
      showToast(
        level: ToastLevel.warning,
        message: '저장된 이미지 파일이 없습니다. 재다운로드를 시도해 주세요.',
      );
      return;
    }

    final articleId = int.tryParse(widget.item.url()) ?? widget.item.id();
    unawaited(
      User.getInstance().then((user) => user.insertUserLog(articleId, 0)),
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) {
          return Provider<ViewerPageProvider>.value(
            value: ViewerPageProvider(
              uris: files,
              useFileSystem: true,
              id: articleId,
              title: widget.item.displayTitle(),
            ),
            child: const ViewerPage(),
          );
        },
      ),
    );
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _showItemMenu() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final state = widget.item.state();
    final diskBytes = await widget.item.calculateDiskSizeBytes();
    final sizeText = _formatBytes(diskBytes.toDouble());
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: Settings.themeWhat.value
          ? const Color(0xFF1E1E1E)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  widget.item.displayTitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _copyArticleId,
                  child: Text('ID: ${widget.item.url()} · 로컬 용량: $sizeText'),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('작품 정보 보기'),
                onTap: () {
                  Navigator.pop(ctx);
                  final qr = widget.item.toQueryResult();
                  if (qr != null) {
                    showArticleInfoRaw(context: context, queryResult: qr);
                  }
                },
              ),
              if (_isRunning)
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('다운로드 중지'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _stopDownload();
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: Text(state == 0 ? '누락 페이지 검사 및 복구' : '이어서 다운로드 (재추출)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _startDownload(skipExisting: true);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text(
                  '삭제 (로컬 파일 포함)',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showYesNoDialog(
                    context,
                    '이 항목과 저장된 이미지 파일($sizeText)을 모두 삭제할까요?',
                  );
                  if (ok == true) {
                    if (_isRunning) {
                      await _stopDownload();
                    }
                    await widget.onDelete(widget.item);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  String? _normalizedRemoteThumbnailUrl() {
    final raw = widget.item.thumbnail()?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('//')) return 'https:$raw';
    return raw.startsWith('http') ? raw : null;
  }

  void _markLocalFileFailed(String filePath) {
    if (_failedLocalFiles.contains(filePath)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _failedLocalFiles.add(filePath);
      });
    });
  }

  Future<void> _refreshRemoteThumbnail() async {
    if (_thumbRefreshAttempted || _refreshingThumb) return;
    _thumbRefreshAttempted = true;
    final qr = widget.item.toQueryResult();
    if (qr == null) return;

    _refreshingThumb = true;
    try {
      final provider = await HentaiManager.getImageProvider(qr);
      await provider.init();
      final url = (await provider.getThumbnailUrl()).trim();
      final header = await provider.getHeader(0);
      if (url.isNotEmpty) {
        final updated = Map<String, dynamic>.from(widget.item.result);
        updated['Thumbnail'] = url.startsWith('//') ? 'https:$url' : url;
        updated['ThumbnailHeader'] = jsonEncode(header);
        widget.item.result = updated;
        unawaited(widget.item.update());
      }
    } catch (_) {
    } finally {
      _refreshingThumb = false;
      if (mounted) {
        setState(() {
          _remoteRetryCount++;
        });
      }
    }
  }

  void _handleRemoteThumbError() {
    if (!_thumbRefreshAttempted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_refreshRemoteThumbnail());
        }
      });
      return;
    }
    if (_remoteRetryCount < 2) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        setState(() {
          _remoteRetryCount++;
        });
      });
    }
  }

  Widget _buildThumbnail({double? width, double? height}) {
    final localCandidates = widget.item
        .candidateThumbnailFiles()
        .where((p) => !_failedLocalFiles.contains(p))
        .toList();
    if (localCandidates.isNotEmpty) {
      final localThumb = localCandidates.first;
      return Image.file(
        File(localThumb),
        key: ValueKey('thumb_file_$localThumb'),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) {
          _markLocalFileFailed(localThumb);
          return _fallbackThumb(width, height);
        },
      );
    }

    final remoteUrl = _normalizedRemoteThumbnailUrl();
    if (remoteUrl != null) {
      Map<String, String>? headers;
      final rawHeader = widget.item.thumbnailHeader();
      if (rawHeader != null && rawHeader.isNotEmpty) {
        try {
          headers = Map<String, String>.from(jsonDecode(rawHeader) as Map);
        } catch (_) {}
      }
      return CachedNetworkImage(
        key: ValueKey('thumb_net_${remoteUrl}_$_remoteRetryCount'),
        imageUrl: remoteUrl,
        httpHeaders: headers,
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (_, _) => _loadingThumb(width, height),
        errorWidget: (_, _, _) {
          _handleRemoteThumbError();
          return _fallbackThumb(width, height);
        },
      );
    }

    if (!_thumbRefreshAttempted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_refreshRemoteThumbnail());
        }
      });
      return _loadingThumb(width, height);
    }

    return _fallbackThumb(width, height);
  }

  Widget _loadingThumb(double? width, double? height) {
    return Container(
      width: width,
      height: height,
      color: Settings.themeWhat.value
          ? Colors.grey.shade800
          : Colors.grey.shade300,
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Settings.majorColor.value.withAlpha(160),
          ),
        ),
      ),
    );
  }

  Widget _fallbackThumb(double? width, double? height) {
    return Container(
      width: width,
      height: height,
      color: Settings.themeWhat.value
          ? Colors.grey.shade800
          : Colors.grey.shade300,
      child: const Icon(Icons.image_not_supported_outlined, size: 28),
    );
  }

  String _statusLabel() {
    switch (widget.item.state()) {
      case 0:
        final pages = widget.item.filesWithoutThumbnail().length;
        return '완료 · ${pages}p';
      case 1:
        return '대기 중...';
      case 2:
        return _extractTotal > 0
            ? '추출 중 ($_extractCurrent/$_extractTotal)'
            : '온라인 메타데이터 추출 중...';
      case 3:
        final sizeStr = _formatBytes(_downloadedBytes);
        return '다운로드 중 ($_downloadDone/$_downloadTotal · $sizeStr)';
      case 6:
        return widget.item.errorMsg() != null
            ? '중지됨 (${widget.item.errorMsg()})'
            : '중지됨';
      case 11:
        return '다운로드할 페이지 없음';
      default:
        return '오류 (${widget.item.errorMsg() ?? '알 수 없음'})';
    }
  }

  Color _statusColor() {
    switch (widget.item.state()) {
      case 0:
        return Colors.green;
      case 1:
      case 2:
      case 3:
        return Settings.majorColor.value;
      case 6:
        return Colors.orange;
      default:
        return Colors.redAccent;
    }
  }

  double? _progressValue() {
    final state = widget.item.state();
    if (state == 2) {
      if (_extractTotal <= 0) return null;
      return (_extractCurrent / _extractTotal).clamp(0.0, 1.0);
    }
    if (state == 3) {
      if (_downloadTotal <= 0) return null;
      return ((_downloadDone + _downloadErrors) / _downloadTotal).clamp(0.0, 1.0);
    }
    return null;
  }

  static String _formatBytes(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (widget.viewType.isGridLike) {
      return _buildGridCard();
    }
    return _buildListCard();
  }

  Widget _buildGridCard() {
    final state = widget.item.state();
    final progress = _progressValue();
    final selected = widget.selectionMode && widget.isSelected;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: Settings.majorColor.value, width: 2.5)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: widget.selectionMode
            ? widget.onToggleSelect
            : (state == 0 ? _openOfflineViewer : _showItemMenu),
        onLongPress: widget.selectionMode
            ? widget.onToggleSelect
            : (widget.onEnterSelectionMode ?? _showItemMenu),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildThumbnail(),
            if (selected)
              Container(
                color: Settings.majorColor.value.withAlpha(45),
              ),
            if (widget.selectionMode)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected ? Settings.majorColor.value : Colors.white,
                    size: 22,
                  ),
                ),
              )
            else
              Positioned(
                top: 2,
                right: 2,
                child: IconButton(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black38,
                    padding: const EdgeInsets.all(4),
                    minimumSize: const Size(28, 28),
                  ),
                  tooltip: '관리 메뉴',
                  onPressed: _showItemMenu,
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.85),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.item.displayTitle(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: _copyArticleId,
                      child: Text(
                        'ID: ${widget.item.url()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: state == 0 ? Colors.greenAccent : Colors.amberAccent,
                        fontSize: 10,
                      ),
                    ),
                    if (state == 2 || state == 3) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListCard() {
    final state = widget.item.state();
    final artist = widget.item.displayArtist();
    final progress = _progressValue();
    final isBig = widget.viewType == DownloadResultType.bigLine;
    final thumbHeight = isBig ? 136.0 : 104.0;
    final thumbWidth = isBig ? 96.0 : 74.0;
    final selected = widget.selectionMode && widget.isSelected;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      clipBehavior: Clip.antiAlias,
      color: selected ? Settings.majorColor.value.withAlpha(28) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: Settings.majorColor.value, width: 1.8)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: widget.selectionMode
            ? widget.onToggleSelect
            : (state == 0 ? _openOfflineViewer : _showItemMenu),
        onLongPress: widget.selectionMode
            ? widget.onToggleSelect
            : (widget.onEnterSelectionMode ?? _showItemMenu),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildThumbnail(width: thumbWidth, height: thumbHeight),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.displayTitle(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: _copyArticleId,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          'ID: ${widget.item.url()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Settings.themeWhat.value
                                ? Colors.grey.shade400
                                : Colors.grey.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Settings.themeWhat.value
                              ? Colors.grey.shade400
                              : Colors.grey.shade700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _statusColor(),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _statusLabel(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _statusColor(),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (state == 1 || state == 2 || state == 3) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (widget.selectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 4, top: 8),
                child: Checkbox(
                  value: selected,
                  activeColor: Settings.majorColor.value,
                  onChanged: (_) => widget.onToggleSelect?.call(),
                ),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isRunning)
                    IconButton(
                      icon: const Icon(Icons.pause_circle_outline),
                      tooltip: '중지',
                      onPressed: _stopDownload,
                    )
                  else if (state != 0)
                    IconButton(
                      icon: const Icon(Icons.play_circle_outline),
                      tooltip: '재개',
                      onPressed: () => _startDownload(skipExisting: true),
                    ),
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    tooltip: '관리 메뉴',
                    onPressed: _showItemMenu,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
