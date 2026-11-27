// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:violet/component/hentai_download_manager.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/other/dialogs.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/download/download_align_type.dart';
import 'package:violet/pages/download/download_id_parser.dart';
import 'package:violet/pages/download/download_item_widget.dart';
import 'package:violet/pages/download/download_view_type.dart';
import 'package:violet/pages/segment/double_tap_to_top.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/style/palette.dart';

enum _DownloadFilter { all, completed, active, stoppedOrError }

class DownloadPageManager {
  static void Function(DownloadItemModel)? _onAppend;
  static void Function(List<DownloadItemModel>)? _onAppendBatch;

  static void attach(
    void Function(DownloadItemModel) listener, {
    void Function(List<DownloadItemModel>)? onBatch,
  }) {
    _onAppend = listener;
    _onAppendBatch = onBatch;
  }

  static void detach(void Function(DownloadItemModel) listener) {
    if (_onAppend == listener) {
      _onAppend = null;
      _onAppendBatch = null;
    }
  }

  static Future<void> appendTaskFromQueryResult(
    QueryResult queryResult, {
    String? thumbnail,
    Map<String, String>? headers,
  }) async {
    final downloadDb = await Download.getInstance();
    final item = await downloadDb.createNew(
      queryResult.id().toString(),
      queryResult: queryResult,
      info: '[${queryResult.id()}] ${queryResult.title()}',
      thumbnail: thumbnail,
      thumbnailHeader: headers != null ? jsonEncode(headers) : null,
    );

    _onAppend?.call(item);
  }

  static Future<void> appendTaskById(String articleId) async {
    await appendTasksByIds([articleId]);
  }

  static Future<List<DownloadItemModel>> appendTasksByIds(
    List<String> articleIds,
  ) async {
    final cleanIds = articleIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (cleanIds.isEmpty) return [];

    final downloadDb = await Download.getInstance();
    final created = <DownloadItemModel>[];
    for (final cleanId in cleanIds) {
      final item = await downloadDb.createNew(cleanId);
      created.add(item);
    }

    _notifyCreated(created);
    return created;
  }

  static Future<List<DownloadItemModel>> appendTasksFromQueryResults(
    List<QueryResult> queryResults,
  ) async {
    if (queryResults.isEmpty) return [];

    final downloadDb = await Download.getInstance();
    final created = <DownloadItemModel>[];
    for (final qr in queryResults) {
      var rawThumb = qr.thumbnail()?.toString().trim() ?? '';
      if (rawThumb.startsWith('//')) {
        rawThumb = 'https:$rawThumb';
      }
      final item = await downloadDb.createNew(
        qr.id().toString(),
        queryResult: qr,
        info: '[${qr.id()}] ${qr.title()}',
        thumbnail: rawThumb.startsWith('http') ? rawThumb : null,
      );
      created.add(item);
    }

    _notifyCreated(created);
    return created;
  }

  static void _notifyCreated(List<DownloadItemModel> created) {
    if (_onAppendBatch != null) {
      _onAppendBatch!.call(created);
    } else {
      for (final item in created) {
        _onAppend?.call(item);
      }
    }
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage>
    with
        AutomaticKeepAliveClientMixin,
        DoubleTapToTopMixin,
        WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _wasKeyboardVisible = false;
  int _suppressSearchFocusCount = 0;
  bool _selectionMode = false;
  final Set<int> _selectedIds = <int>{};
  final StreamController<(int, DownloadBatchAction)> _batchActionController =
      StreamController<(int, DownloadBatchAction)>.broadcast();
  List<DownloadItemModel> _allItems = [];
  _DownloadFilter _filter = _DownloadFilter.all;
  String _searchQuery = '';
  bool _loading = true;
  int _totalDiskBytes = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    doubleTapToTopScrollController = _scrollController;
    DownloadPageManager.attach(appendItem, onBatch: appendItems);
    unawaited(_loadItems());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DownloadPageManager.detach(appendItem);
    unawaited(_batchActionController.close());
    _searchFocusNode.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final isKeyboardVisible = views.first.viewInsets.bottom > 0;
    if (_wasKeyboardVisible &&
        !isKeyboardVisible &&
        _searchFocusNode.hasFocus) {
      _unfocusSearch();
    }
    _wasKeyboardVisible = isKeyboardVisible;
  }

  void _unfocusSearch() {
    _searchFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<T> _runWithSuppressedSearchFocus<T>(
    Future<T> Function() action,
  ) async {
    _unfocusSearch();
    _suppressSearchFocusCount++;
    _searchFocusNode.canRequestFocus = false;
    try {
      return await action();
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _suppressSearchFocusCount = math.max(0, _suppressSearchFocusCount - 1);
        if (!mounted) return;
        if (_suppressSearchFocusCount == 0) {
          _searchFocusNode.canRequestFocus = true;
        }
      });
    }
  }

  void appendItem(DownloadItemModel item) {
    setState(() {
      _allItems.insert(0, item);
    });
  }

  void appendItems(List<DownloadItemModel> items) {
    if (items.isEmpty) return;
    setState(() {
      for (final item in items) {
        _allItems.insert(0, item);
      }
    });
  }

  Future<void> _loadItems() async {
    setState(() {
      _loading = true;
    });
    final db = await Download.getInstance();
    final items = await db.getDownloadItems();
    items.sort((a, b) => b.id().compareTo(a.id()));
    if (!mounted) return;
    setState(() {
      _allItems = items;
      _loading = false;
    });
    unawaited(_recalculateTotalSize());
  }

  Future<void> _recalculateTotalSize() async {
    int total = 0;
    for (final item in List<DownloadItemModel>.from(_allItems)) {
      total += await item.calculateDiskSizeBytes();
    }
    if (!mounted) return;
    setState(() {
      _totalDiskBytes = total;
    });
  }

  Future<void> _deleteItem(DownloadItemModel item) async {
    await item.deleteWithFiles();
    final articleId = int.tryParse(item.url());
    if (articleId != null) {
      (await Download.getInstance()).removeDownloaded(articleId);
    }
    if (!mounted) return;
    setState(() {
      _allItems.removeWhere((e) => e.id() == item.id());
      _selectedIds.remove(item.id());
    });
    unawaited(_recalculateTotalSize());
    showToast(
      icon: Icons.delete_outline,
      level: ToastLevel.check,
      message: '다운로드 항목과 파일을 삭제했습니다.',
    );
  }

  void _enterSelectionMode([DownloadItemModel? initialItem]) {
    _unfocusSearch();
    setState(() {
      _selectionMode = true;
      _selectedIds.clear();
      if (initialItem != null) {
        _selectedIds.add(initialItem.id());
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelectItem(DownloadItemModel item) {
    setState(() {
      if (!_selectedIds.add(item.id())) {
        _selectedIds.remove(item.id());
      }
    });
  }

  void _toggleSelectAll(List<DownloadItemModel> visibleItems) {
    final visibleIds = visibleItems.map((e) => e.id()).toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedIds.contains);
    setState(() {
      if (allSelected) {
        _selectedIds.removeAll(visibleIds);
      } else {
        _selectedIds.addAll(visibleIds);
      }
    });
  }

  List<DownloadItemModel> _selectedItemsInOrder(
    List<DownloadItemModel> visibleItems,
  ) {
    final ordered = <DownloadItemModel>[];
    final added = <int>{};
    for (final item in visibleItems) {
      if (_selectedIds.contains(item.id()) && added.add(item.id())) {
        ordered.add(item);
      }
    }
    for (final item in _allItems) {
      if (_selectedIds.contains(item.id()) && added.add(item.id())) {
        ordered.add(item);
      }
    }
    return ordered;
  }

  Future<void> _copySelectedIds(List<DownloadItemModel> visibleItems) async {
    final selected = _selectedItemsInOrder(visibleItems);
    final ids = <String>[];
    final seen = <String>{};
    for (final item in selected) {
      final url = item.url().trim();
      if (url.isNotEmpty && seen.add(url)) {
        ids.add(url);
      }
    }
    if (ids.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: ids.join(', ')));
    showToast(
      icon: Icons.copy,
      level: ToastLevel.check,
      message: '${ids.length}개 작품 번호를 복사했습니다.',
    );
  }

  void _batchResumeSelected(List<DownloadItemModel> visibleItems) {
    final targets = _selectedItemsInOrder(visibleItems)
        .where((e) => e.state() != 0)
        .toList();
    if (targets.isEmpty) {
      showToast(
        level: ToastLevel.warning,
        message: '재개할 미완료 항목이 없습니다.',
      );
      return;
    }
    for (final item in targets) {
      _batchActionController.add((item.id(), DownloadBatchAction.resume));
    }
    _exitSelectionMode();
    showToast(
      icon: Icons.play_arrow,
      level: ToastLevel.check,
      message: '${targets.length}개 작품 다운로드를 재개했습니다.',
    );
  }

  void _batchStopSelected(List<DownloadItemModel> visibleItems) {
    final targets = _selectedItemsInOrder(visibleItems)
        .where((e) => e.state() == 1 || e.state() == 2 || e.state() == 3)
        .toList();
    if (targets.isEmpty) {
      showToast(
        level: ToastLevel.warning,
        message: '중지할 진행 중 항목이 없습니다.',
      );
      return;
    }
    for (final item in targets) {
      _batchActionController.add((item.id(), DownloadBatchAction.stop));
    }
    _exitSelectionMode();
    showToast(
      icon: Icons.pause,
      level: ToastLevel.check,
      message: '${targets.length}개 작품 다운로드를 중지했습니다.',
    );
  }

  Future<void> _batchDeleteSelected(
    List<DownloadItemModel> visibleItems,
  ) async {
    final targets = _selectedItemsInOrder(visibleItems);
    if (targets.isEmpty) return;

    int totalBytes = 0;
    for (final item in targets) {
      totalBytes += await item.calculateDiskSizeBytes();
    }
    if (!mounted) return;

    final confirmed = await _runWithSuppressedSearchFocus(
      () => showYesNoDialog(
        context,
        '선택한 ${targets.length}개 작품과 저장된 파일(${_formatSize(totalBytes)})을 모두 삭제할까요?',
      ),
    );
    if (confirmed != true) return;

    final db = await Download.getInstance();
    final targetIds = targets.map((e) => e.id()).toSet();
    for (final item in targets) {
      _batchActionController.add((item.id(), DownloadBatchAction.stop));
      await item.deleteWithFiles();
      final articleId = int.tryParse(item.url());
      if (articleId != null) {
        db.removeDownloaded(articleId);
      }
    }

    if (!mounted) return;
    setState(() {
      _allItems.removeWhere((e) => targetIds.contains(e.id()));
      _selectionMode = false;
      _selectedIds.clear();
    });
    unawaited(_recalculateTotalSize());
    showToast(
      icon: Icons.delete_outline,
      level: ToastLevel.check,
      message: '${targets.length}개 작품과 파일을 삭제했습니다.',
    );
  }

  Future<void> _promptAddById() async {
    await _runWithSuppressedSearchFocus(() async {
      if (Platform.isAndroid &&
          !Settings.useInnerStorage.value &&
          !await Permission.manageExternalStorage.isGranted) {
        if (await Permission.manageExternalStorage.request() ==
            PermissionStatus.denied) {
          if (!mounted) return;
          await showOkDialog(
            context,
            '외부 저장소 권한을 허용하지 않으면 다운로드할 수 없습니다.',
          );
          return;
        }
      }

      if (!mounted) return;
      final existingUrls = _allItems.map((e) => e.url().trim()).toSet();
      final selectedResults = await showDialog<List<QueryResult>>(
        context: context,
        builder: (ctx) => _AddByIdDialog(existingUrls: existingUrls),
      );

      if (selectedResults == null || selectedResults.isEmpty) return;

      final duplicateIds = selectedResults
          .map((e) => e.id().toString())
          .where(existingUrls.contains)
          .toList();
      final newResults = selectedResults
          .where((e) => !existingUrls.contains(e.id().toString()))
          .toList();

      List<QueryResult> finalResults = selectedResults;
      if (duplicateIds.isNotEmpty) {
        if (!mounted) return;
        if (newResults.isEmpty) {
          final proceed = await showYesNoDialog(
            context,
            '입력한 작품(${duplicateIds.join(', ')})은 이미 다운로드 목록에 있습니다. 그래도 다시 추가할까요?',
          );
          if (proceed != true) return;
        } else {
          final choice = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('중복 작품 확인'),
              content: Text(
                '이미 다운로드 목록에 있는 작품(${duplicateIds.join(', ')})이 포함되어 있습니다.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'all'),
                  child: Text('모두 추가 (${selectedResults.length})'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Settings.majorColor.value,
                  ),
                  onPressed: () => Navigator.pop(ctx, 'new_only'),
                  child: Text('중복 제외 (${newResults.length})'),
                ),
              ],
            ),
          );
          if (choice == null) return;
          if (choice == 'new_only') {
            finalResults = newResults;
          }
        }
      }

      await DownloadPageManager.appendTasksFromQueryResults(finalResults);
      final finalIds = finalResults.map((e) => e.id().toString()).toList();
      final message = finalIds.length == 1
          ? '${finalIds.first} 다운로드 큐에 추가했습니다.'
          : finalIds.length <= 3
          ? '${finalIds.length}개 작품(${finalIds.join(', ')})을 다운로드 큐에 추가했습니다.'
          : '${finalIds.length}개 작품을 다운로드 큐에 추가했습니다.';
      showToast(
        icon: Icons.download,
        level: ToastLevel.check,
        message: message,
      );
    });
  }

  List<DownloadItemModel> _filteredAndSortedItems() {
    final query = _searchQuery.trim().toLowerCase();
    final filtered = _allItems.where((item) {
      final state = item.state();
      switch (_filter) {
        case _DownloadFilter.completed:
          if (state != 0) return false;
          break;
        case _DownloadFilter.active:
          if (state != 1 && state != 2 && state != 3) return false;
          break;
        case _DownloadFilter.stoppedOrError:
          if (state == 0 || state == 1 || state == 2 || state == 3) {
            return false;
          }
          break;
        case _DownloadFilter.all:
          break;
      }

      if (query.isEmpty) return true;
      final title = item.displayTitle().toLowerCase();
      final artist = item.displayArtist().toLowerCase();
      final id = item.url().toLowerCase();
      final tags = (item.toQueryResult()?.tags()?.toString() ?? '').toLowerCase();
      return title.contains(query) ||
          artist.contains(query) ||
          id.contains(query) ||
          tags.contains(query);
    }).toList();

    final align = Settings.downloadAlignType.value;
    switch (align) {
      case 1: // 작가순
        filtered.sort(
          (a, b) => a.displayArtist().toLowerCase().compareTo(
            b.displayArtist().toLowerCase(),
          ),
        );
        break;
      case 2: // 그룹순
        filtered.sort((a, b) {
          final ga = (a.toQueryResult()?.groups()?.toString() ?? '').toLowerCase();
          final gb = (b.toQueryResult()?.groups()?.toString() ?? '').toLowerCase();
          return ga.compareTo(gb);
        });
        break;
      case 3: // 페이지순
        filtered.sort(
          (a, b) => b
              .filesWithoutThumbnail()
              .length
              .compareTo(a.filesWithoutThumbnail().length),
        );
        break;
      case 4: // 제목순
        filtered.sort(
          (a, b) => a.displayTitle().toLowerCase().compareTo(
            b.displayTitle().toLowerCase(),
          ),
        );
        break;
      default: // 최신순
        filtered.sort((a, b) => b.id().compareTo(a.id()));
        break;
    }

    return filtered;
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final items = _filteredAndSortedItems();
    final viewType = Settings.downloadResultType.value;
    final completedCount = _allItems.where((e) => e.state() == 0).length;

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) {
          _exitSelectionMode();
        }
      },
      child: Scaffold(
        backgroundColor: Palette.themeColor,
        body: SafeArea(
          child: Column(
            children: [
              _selectionMode
                  ? _buildSelectionHeader(items)
                  : _buildHeader(completedCount),
              _buildSearchAndFilters(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : items.isEmpty
                    ? _buildEmptyView()
                    : RefreshIndicator(
                        onRefresh: _loadItems,
                        child: viewType.isGridLike
                            ? GridView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.all(8),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount:
                                          viewType.isThreeGrid ? 3 : 2,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                      childAspectRatio: 0.7,
                                    ),
                                itemCount: items.length,
                                itemBuilder: (context, index) {
                                  final item = items[index];
                                  return DownloadItemWidget(
                                    key: ValueKey('dl_${item.id()}'),
                                    item: item,
                                    viewType: viewType,
                                    selectionMode: _selectionMode,
                                    isSelected: _selectedIds.contains(
                                      item.id(),
                                    ),
                                    onToggleSelect: () =>
                                        _toggleSelectItem(item),
                                    onEnterSelectionMode: () =>
                                        _enterSelectionMode(item),
                                    batchActionStream:
                                        _batchActionController.stream,
                                    onChanged: () {
                                      if (mounted) {
                                        setState(() {});
                                        unawaited(_recalculateTotalSize());
                                      }
                                    },
                                    onDelete: _deleteItem,
                                  );
                                },
                              )
                            : ListView.builder(
                                controller: _scrollController,
                                padding: EdgeInsets.only(
                                  bottom: _selectionMode ? 12 : 80,
                                ),
                                itemCount: items.length,
                                itemBuilder: (context, index) {
                                  final item = items[index];
                                  return DownloadItemWidget(
                                    key: ValueKey('dl_${item.id()}'),
                                    item: item,
                                    viewType: viewType,
                                    selectionMode: _selectionMode,
                                    isSelected: _selectedIds.contains(
                                      item.id(),
                                    ),
                                    onToggleSelect: () =>
                                        _toggleSelectItem(item),
                                    onEnterSelectionMode: () =>
                                        _enterSelectionMode(item),
                                    batchActionStream:
                                        _batchActionController.stream,
                                    onChanged: () {
                                      if (mounted) {
                                        setState(() {});
                                        unawaited(_recalculateTotalSize());
                                      }
                                    },
                                    onDelete: _deleteItem,
                                  );
                                },
                              ),
                      ),
              ),
              if (_selectionMode) _buildSelectionActionBar(items),
            ],
          ),
        ),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                heroTag: 'download_add_fab',
                backgroundColor: Settings.majorColor.value,
                onPressed: _promptAddById,
                tooltip: '작품 ID로 다운로드',
                child: const Icon(Icons.add, color: Colors.white),
              ),
      ),
    );
  }

  Widget _buildSelectionHeader(List<DownloadItemModel> visibleItems) {
    final visibleIds = visibleItems.map((e) => e.id()).toSet();
    final allVisibleSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedIds.contains);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '선택 취소',
            onPressed: _exitSelectionMode,
          ),
          Expanded(
            child: Text(
              '${_selectedIds.length}개 선택됨',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          TextButton.icon(
            onPressed: visibleItems.isEmpty
                ? null
                : () => _toggleSelectAll(visibleItems),
            icon: Icon(
              allVisibleSelected ? Icons.deselect : Icons.select_all,
              size: 20,
            ),
            label: Text(allVisibleSelected ? '선택 해제' : '전체 선택'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionActionBar(List<DownloadItemModel> visibleItems) {
    final hasSelection = _selectedIds.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: Settings.themeWhat.value
            ? const Color(0xFF1F1F1F)
            : Colors.white,
        border: Border(
          top: BorderSide(
            color: Settings.themeWhat.value
                ? Colors.grey.shade800
                : Colors.grey.shade300,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _selectionActionButton(
            icon: Icons.copy,
            label: 'ID 복사',
            enabled: hasSelection,
            onTap: () => _copySelectedIds(visibleItems),
          ),
          _selectionActionButton(
            icon: Icons.play_arrow,
            label: '이어받기',
            enabled: hasSelection,
            onTap: () => _batchResumeSelected(visibleItems),
          ),
          _selectionActionButton(
            icon: Icons.pause,
            label: '중지',
            enabled: hasSelection,
            onTap: () => _batchStopSelected(visibleItems),
          ),
          _selectionActionButton(
            icon: Icons.delete_outline,
            label: '삭제',
            enabled: hasSelection,
            color: Colors.redAccent,
            onTap: () => _batchDeleteSelected(visibleItems),
          ),
        ],
      ),
    );
  }

  Widget _selectionActionButton({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
    Color? color,
  }) {
    final effectiveColor = enabled
        ? (color ??
              (Settings.themeWhat.value ? Colors.white : Colors.black87))
        : Colors.grey;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: effectiveColor),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: effectiveColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(int completedCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '다운로드 관리',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '완료 $completedCount / 전체 ${_allItems.length} · ${_formatSize(_totalDiskBytes)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Settings.themeWhat.value
                        ? Colors.grey.shade400
                        : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.checklist),
            tooltip: '다중 선택',
            onPressed: _allItems.isEmpty ? null : () => _enterSelectionMode(),
          ),
          IconButton(
            icon: const Icon(MdiIcons.sort),
            tooltip: '정렬',
            onPressed: () async {
              await _runWithSuppressedSearchFocus(
                () => showDialog(
                  context: context,
                  builder: (_) => const DownloadAlignType(),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.view_module_outlined),
            tooltip: '보기 방식',
            onPressed: () async {
              await _runWithSuppressedSearchFocus(
                () => showDialog(
                  context: context,
                  builder: (_) => const DownloadViewType(),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: _loadItems,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onTapOutside: (_) => _unfocusSearch(),
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: '제목, 작가, 태그, ID 검색 (오프라인 지원)',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip('전체', _DownloadFilter.all),
                const SizedBox(width: 6),
                _filterChip('완료', _DownloadFilter.completed),
                const SizedBox(width: 6),
                _filterChip('진행 중', _DownloadFilter.active),
                const SizedBox(width: 6),
                _filterChip('중지/실패', _DownloadFilter.stoppedOrError),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, _DownloadFilter value) {
    final selected = _filter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: Settings.majorColor.value.withOpacity(0.25),
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_for_offline_outlined,
            size: 56,
            color: Colors.grey.shade500,
          ),
          const SizedBox(height: 12),
          Text(
            _allItems.isEmpty
                ? '다운로드한 작품이 없습니다.\n작품 정보에서 다운로드를 누르거나 + 버튼으로 추가해 보세요.'
                : '조건에 맞는 다운로드 항목이 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

class _AddByIdDialog extends StatefulWidget {
  final Set<String> existingUrls;

  const _AddByIdDialog({required this.existingUrls});

  @override
  State<_AddByIdDialog> createState() => _AddByIdDialogState();
}

class _AddByIdDialogState extends State<_AddByIdDialog> {
  final TextEditingController _controller = TextEditingController();
  final Map<String, QueryResult> _verifiedCache = {};
  Set<String> _notFoundIds = {};
  bool _verifying = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verifyAndSubmit(List<String> ids) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _notFoundIds = {};
    });

    final manager = HentaiDonwloadManager.instance();
    final results = await Future.wait(
      ids.map((id) async {
        final cached = _verifiedCache[id];
        if (cached != null) return MapEntry<String, QueryResult?>(id, cached);
        final resolved = await manager.verifyOnlineArticle(id);
        return MapEntry<String, QueryResult?>(id, resolved);
      }),
    );

    if (!mounted) return;

    final notFound = <String>{};
    final verified = <QueryResult>[];
    for (final entry in results) {
      if (entry.value == null) {
        notFound.add(entry.key);
      } else {
        _verifiedCache[entry.key] = entry.value!;
        verified.add(entry.value!);
      }
    }

    if (notFound.isNotEmpty) {
      setState(() {
        _verifying = false;
        _notFoundIds = notFound;
      });
      return;
    }

    Navigator.pop(context, verified);
  }

  Widget _buildChip({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(140)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parsed = parseDownloadIds(_controller.text);
    final hasInput = _controller.text.trim().isNotEmpty;
    final canSubmit =
        !_verifying && parsed.validIds.isNotEmpty && !parsed.hasErrors;

    String? statusText;
    Color statusColor = Colors.grey;
    if (_verifying) {
      statusText = '작품 번호가 실제로 존재하는지 확인 중입니다...';
      statusColor = Settings.majorColor.value;
    } else if (_notFoundIds.isNotEmpty) {
      statusText =
          '존재하지 않는 작품 번호가 포함되어 있습니다: ${_notFoundIds.join(', ')}';
      statusColor = Colors.redAccent;
    } else if (parsed.hasErrors) {
      statusText =
          '숫자가 아닌 값이 포함되어 있습니다: ${parsed.invalidTokens.join(', ')}';
      statusColor = Colors.redAccent;
    } else if (parsed.duplicateInputIds.isNotEmpty) {
      statusText =
          '입력 내 중복(${parsed.duplicateInputIds.join(', ')})을 제외하고 ${parsed.validIds.length}개가 추가됩니다.';
      statusColor = Colors.orangeAccent;
    } else if (parsed.validIds.isNotEmpty) {
      statusText = '총 ${parsed.validIds.length}개 작품이 다운로드 목록에 추가됩니다.';
      statusColor = Settings.majorColor.value;
    }

    return AlertDialog(
      title: const Text('작품 ID로 다운로드'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              enabled: !_verifying,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: 4,
              autofocus: true,
              onChanged: (_) => setState(() {
                _notFoundIds = {};
              }),
              decoration: const InputDecoration(
                hintText: '예: 100, 200 또는 1234567',
                labelText: '작품 번호 (쉼표나 공백으로 여러 개 입력 가능)',
              ),
            ),
            if (hasInput) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in parsed.validIds)
                    _buildChip(
                      label: _notFoundIds.contains(id)
                          ? '#$id (존재하지 않음)'
                          : widget.existingUrls.contains(id)
                          ? '#$id (목록에 있음)'
                          : '#$id',
                      color: _notFoundIds.contains(id)
                          ? Colors.redAccent
                          : widget.existingUrls.contains(id)
                          ? Colors.orangeAccent
                          : Settings.majorColor.value,
                    ),
                  for (final bad in parsed.invalidTokens)
                    _buildChip(
                      label: '$bad (오류)',
                      color: Colors.redAccent,
                    ),
                ],
              ),
            ],
            if (statusText != null) ...[
              const SizedBox(height: 8),
              Text(
                statusText,
                style: TextStyle(fontSize: 12, color: statusColor),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Settings.majorColor.value,
          ),
          onPressed:
              canSubmit ? () => _verifyAndSubmit(parsed.validIds) : null,
          child: _verifying
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: 6),
                    Text('확인 중...'),
                  ],
                )
              : Text(
                  parsed.validIds.length > 1
                      ? '추가 (${parsed.validIds.length})'
                      : '추가',
                ),
        ),
      ],
    );
  }
}
