// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/other/dialogs.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/download/download_align_type.dart';
import 'package:violet/pages/download/download_item_widget.dart';
import 'package:violet/pages/download/download_view_type.dart';
import 'package:violet/pages/segment/double_tap_to_top.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/style/palette.dart';

enum _DownloadFilter { all, completed, active, stoppedOrError }

class DownloadPageManager {
  static void Function(DownloadItemModel)? _onAppend;

  static void attach(void Function(DownloadItemModel) listener) {
    _onAppend = listener;
  }

  static void detach(void Function(DownloadItemModel) listener) {
    if (_onAppend == listener) {
      _onAppend = null;
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
    final cleanId = articleId.trim();
    if (cleanId.isEmpty) return;

    final downloadDb = await Download.getInstance();
    final item = await downloadDb.createNew(cleanId);

    _onAppend?.call(item);
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage>
    with AutomaticKeepAliveClientMixin, DoubleTapToTopMixin {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  final TextEditingController _searchController = TextEditingController();
  List<DownloadItemModel> _allItems = [];
  _DownloadFilter _filter = _DownloadFilter.all;
  String _searchQuery = '';
  bool _loading = true;
  int _totalDiskBytes = 0;

  @override
  void initState() {
    super.initState();
    doubleTapToTopScrollController = _scrollController;
    DownloadPageManager.attach(appendItem);
    unawaited(_loadItems());
  }

  @override
  void dispose() {
    DownloadPageManager.detach(appendItem);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void appendItem(DownloadItemModel item) {
    setState(() {
      _allItems.insert(0, item);
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
    });
    unawaited(_recalculateTotalSize());
    showToast(
      icon: Icons.delete_outline,
      level: ToastLevel.check,
      message: '다운로드 항목과 파일을 삭제했습니다.',
    );
  }

  Future<void> _promptAddById() async {
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
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('작품 ID로 다운로드'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '예: 1234567',
            labelText: '작품 번호 (Hitomi / E-Hentai ID)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Settings.majorColor.value,
            ),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('추가'),
          ),
        ],
      ),
    );

    if (result != null && RegExp(r'^\d+$').hasMatch(result)) {
      await DownloadPageManager.appendTaskById(result);
      showToast(
        icon: Icons.download,
        level: ToastLevel.check,
        message: '$result 다운로드 큐에 추가했습니다.',
      );
    } else if (result != null && result.isNotEmpty) {
      showToast(
        level: ToastLevel.warning,
        message: '숫자로 된 작품 ID를 입력해 주세요.',
      );
    }
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

    return Scaffold(
      backgroundColor: Palette.themeColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(completedCount),
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
                              padding: const EdgeInsets.only(bottom: 80),
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                return DownloadItemWidget(
                                  key: ValueKey('dl_${item.id()}'),
                                  item: item,
                                  viewType: viewType,
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
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'download_add_fab',
        backgroundColor: Settings.majorColor.value,
        onPressed: _promptAddById,
        tooltip: '작품 ID로 다운로드',
        child: const Icon(Icons.add, color: Colors.white),
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
            icon: const Icon(MdiIcons.sort),
            tooltip: '정렬',
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => const DownloadAlignType(),
              );
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.view_module_outlined),
            tooltip: '보기 방식',
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => const DownloadViewType(),
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
