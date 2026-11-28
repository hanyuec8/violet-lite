// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:violet/component/hitomi/message_corpus_manager.dart';
import 'package:violet/component/index.dart';
import 'package:violet/locale/locale.dart';
import 'package:violet/log/log.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/search/search_page_controller.dart';
import 'package:violet/pages/settings/settings_widgets.dart';
import 'package:violet/pages/settings/tag_rebuild_page.dart';
import 'package:violet/pages/settings/tag_selector.dart';
import 'package:violet/settings/settings.dart';

List<Widget> buildSearchGroup(BuildContext context, VoidCallback onReload) {
  return [
    SettingGroupName(name: Translations.instance!.trans('search')),
    buildSettingItems([
      InkWell(
        customBorder: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(8.0),
            topRight: Radius.circular(8.0),
          ),
        ),
        child: ListTile(
          leading: Icon(
            MdiIcons.translate,
            color: Settings.majorColor.value,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('기본 검색 언어 설정'),
              Text(
                '현재 언어: ${_getLanguageName(Settings.includeTags.value)}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          trailing: const Icon(Icons.keyboard_arrow_right),
        ),
        onTap: () async {
          await _showLanguageSelectorAndRebuild(context, onReload);
        },
      ),
      ListTile(
        leading: Icon(MdiIcons.tag, color: Settings.majorColor.value),
        title: Text(Translations.instance!.trans('defaulttag')),
        subtitle: Text(
          Settings.normalizedDefaultTags.isNotEmpty
              ? Settings.normalizedDefaultTags
              : '설정된 기본 태그 없음',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
          ),
        ),
        trailing: const Icon(Icons.keyboard_arrow_right),
        onTap: () async {
          final vv = await showDialog<(int, String)?>(
            context: context,
            builder: (BuildContext context) =>
                const TagSelectorDialog(what: 'default'),
          );

          if (vv?.$1 == 1) {
            final normalized =
                vv!.$2.trim().replaceAll(RegExp(r'\s+'), ' ');
            await Settings.defaultTags.setValue(normalized);
            SearchPageController.current?.doSearch();
            onReload();
          }
        },
      ),
      ListTile(
        leading: Icon(MdiIcons.tagOff, color: Settings.majorColor.value),
        title: Text(Translations.instance!.trans('excludetag')),
        trailing: const Icon(Icons.keyboard_arrow_right),
        onTap: () async {
          final vv = await showDialog<(int, String)?>(
            context: context,
            builder: (BuildContext context) =>
                const TagSelectorDialog(what: 'exclude'),
          );

          if (vv?.$1 == 1) {
            final cleanTags = <String>[];
            for (final raw in vv!.$2.split(RegExp(r'\s+'))) {
              final e = raw.trim();
              if (e.isEmpty) continue;
              if (RegExp(r'^-?\d+(?:,-?\d+)+$').hasMatch(e)) {
                for (final part in e.split(',')) {
                  final p = part.trim();
                  if (p.isNotEmpty) cleanTags.add(p);
                }
              } else {
                cleanTags.add(e);
              }
            }
            await Settings.excludeTags.setValue(cleanTags);
            SearchPageController.current?.applyExcludedTagsFilter();
            onReload();
          }
        },
      ),
      ListTile(
        leading: Icon(
          MdiIcons.deleteRestore,
          color: Settings.majorColor.value,
        ),
        title: const Text('삭제된(Expunged) 작품 포함'),
        subtitle: Text(
          '업데이트: ${Settings.lastExpungedSyncTime.value.isNotEmpty ? Settings.lastExpungedSyncTime.value.split('T').first : '2026-11-01'}',
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade600,
          ),
        ),
        trailing: Switch(
          value: Settings.searchExpunged.value,
          onChanged: (newValue) async {
            await Settings.searchExpunged.setValue(newValue);
            onReload();
          },
          activeTrackColor: Settings.majorColor.value,
          activeThumbColor: Settings.majorAccentColor.value,
        ),
      ),
      ListTile(
        leading: Icon(
          Icons.library_books,
          color: Settings.majorColor.value,
        ),
        title: const Text('작품 그룹화 (다국어/중복 묶기)'),
        subtitle: const Text(
          '같은 작품의 번역본·중복을 하나로 묶어 표시합니다.',
          style: TextStyle(fontSize: 12),
        ),
        trailing: Switch(
          value: Settings.groupByFirstPage.value,
          onChanged: (newValue) async {
            await Settings.groupByFirstPage.setValue(newValue);
            onReload();
          },
          activeTrackColor: Settings.majorColor.value,
          activeThumbColor: Settings.majorAccentColor.value,
        ),
      ),
      ListTile(
        leading: Icon(
          MdiIcons.keyboardOutline,
          color: Settings.majorColor.value,
        ),
        title: const Text('한글·영타 오타 자동 복원기'),
        subtitle: const Text(
          '한/영 입력 오타를 자동으로 변환해 검색합니다.',
          style: TextStyle(fontSize: 12),
        ),
        trailing: Switch(
          value: Settings.enableHangulTypoRestore.value,
          onChanged: (newValue) async {
            await Settings.enableHangulTypoRestore.setValue(newValue);
            onReload();
          },
          activeTrackColor: Settings.majorColor.value,
          activeThumbColor: Settings.majorAccentColor.value,
        ),
      ),
      _MessageSearchSettingTile(onReload: onReload),
      InkWell(
        customBorder: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(8.0),
            bottomRight: Radius.circular(8.0),
          ),
        ),
        child: ListTile(
          leading: CachedNetworkImage(
            imageUrl: 'https://e-hentai.org/favicon.ico',
            width: 25,
          ),
          title: const Text('Search Categories'),
            trailing: const Icon(Icons.keyboard_arrow_right),
          ),
          onTap: () async {
            var cats = Settings.searchCategory.value;

            var catsController = TextEditingController(text: '$cats');

            getButton(String name, int cat) {
              return CategoryButton(
                name: name,
                controller: catsController,
                cat: cat,
              );
            }

            final doujinshiButton = getButton('Doujinshi', 1);
            final mangaButton = getButton('Manga', 2);
            final artistcgButton = getButton('Artist CG', 3);
            final gamecgButton = getButton('Game CG', 4);
            final westernButton = getButton('Western', 9);
            final nonhButton = getButton('Non-H', 8);
            final imagesetButton = getButton('Image Set', 5);
            final cosplayButton = getButton('Cosplay', 6);
            final asianpornButton = getButton('Asian Porn', 7);
            final miscButton = getButton('Misc', 0);

            Widget okButton = TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Settings.majorColor.value,
              ),
              child: Text(Translations.instance!.trans('ok')),
              onPressed: () {
                try {
                  cats = int.parse(catsController.text);
                  Settings.searchCategory.setValue(cats);
                } catch (e, st) {
                  Logger.error(
                    '[Search Categories] $e\n'
                    '$st',
                  );
                }
                Navigator.pop(context);
              },
            );
            Widget cancelButton = TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Settings.majorColor.value,
              ),
              child: Text(Translations.instance!.trans('cancel')),
              onPressed: () {
                Navigator.pop(context);
              },
            );
            await showDialog(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                actions: [okButton, cancelButton],
                title: const Text('E-Hentai Categories'),
                contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('f_cats: '),
                      ...[
                        TextField(controller: catsController, readOnly: true),
                        doujinshiButton,
                        mangaButton,
                        artistcgButton,
                        gamecgButton,
                        westernButton,
                        nonhButton,
                        imagesetButton,
                        cosplayButton,
                        asianpornButton,
                        miscButton,
                      ].map((e) => Row(children: [Expanded(child: e)])),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
    ]),
  ];
}

String _getLanguageName(String includeTags) {
  final val = includeTags.toLowerCase().trim();
  if (val.isEmpty || val == 'all') return '전체 (언어 필터 없음)';

  final matched = <String>[];
  if (val.contains('korean')) matched.add('한국어');
  if (val.contains('japanese')) matched.add('일본어');
  if (val.contains('english')) matched.add('영어');
  if (val.contains('chinese')) matched.add('중국어');

  if (matched.isNotEmpty) {
    return matched.join(', ');
  }
  return val;
}

Future<void> _showLanguageSelectorAndRebuild(
  BuildContext context,
  VoidCallback onReload,
) async {
  final availableLanguages = [
    ('🇰🇷 한국어 (Korean)', 'korean'),
    ('🇯🇵 일본어 (Japanese)', 'japanese'),
    ('🇺🇸 영어 (English)', 'english'),
    ('🇨🇳 중국어 (Chinese)', 'chinese'),
  ];

  final currentInclude = Settings.includeTags.value.toLowerCase();
  final selectedLangs = <String>{};
  for (var lang in availableLanguages) {
    if (currentInclude.contains(lang.$2)) {
      selectedLangs.add(lang.$2);
    }
  }

  final result = await showDialog<String>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.language, size: 24),
                SizedBox(width: 8),
                Text('기본 검색 언어 설정'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '원하는 언어를 복수 선택할 수 있습니다.\n설정 시 자동으로 태그 리빌딩이 진행됩니다.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),
                  ...availableLanguages.map((item) {
                    final isChecked = selectedLangs.contains(item.$2);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        item.$1,
                        style: TextStyle(
                          fontWeight:
                              isChecked ? FontWeight.bold : FontWeight.normal,
                          color: isChecked ? Settings.majorColor.value : null,
                        ),
                      ),
                      value: isChecked,
                      activeColor: Settings.majorColor.value,
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            selectedLangs.add(item.$2);
                          } else {
                            selectedLangs.remove(item.$2);
                          }
                        });
                      },
                    );
                  }),
                  const Divider(height: 16),
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.select_all, size: 18),
                        label: const Text('전체 언어'),
                        style: TextButton.styleFrom(
                          foregroundColor: Settings.majorColor.value,
                        ),
                        onPressed: () {
                          setState(() {
                            selectedLangs.clear();
                          });
                        },
                      ),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.edit, size: 18),
                        label: const Text('직접 입력'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey.shade600,
                        ),
                        onPressed: () {
                          Navigator.pop(context, '__custom__');
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: Text(
                  Translations.instance!.trans('cancel'),
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Settings.majorColor.value,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  if (selectedLangs.isEmpty) {
                    Navigator.pop(context, '');
                  } else if (selectedLangs.length == 1) {
                    Navigator.pop(context, '(lang:${selectedLangs.first})');
                  } else {
                    final query =
                        '(${selectedLangs.map((e) => 'lang:$e').join(' or ')})';
                    Navigator.pop(context, query);
                  }
                },
                child: const Text('저장 및 리빌딩'),
              ),
            ],
          );
        },
      );
    },
  );

  if (result == null) return;

  if (result == '__custom__') {
    if (!context.mounted) return;
    final vv = await showDialog(
      context: context,
      builder: (BuildContext context) =>
          const TagSelectorDialog(what: 'include'),
    );

    if (vv != null && vv.$1 == 1) {
      await Settings.includeTags.setValue(vv.$2);
      onReload();
    }
    return;
  }

  // 언어 태그 저장
  await Settings.includeTags.setValue(result);

  if (!context.mounted) return;

  // 태그 리빌딩 자동 실행
  await showDialog(
    context: context,
    builder: (BuildContext context) => const TagRebuildPage(),
  );

  await HentaiIndex.init();
  onReload();

  final langDisplay = _getLanguageName(result);
  showToast(
    level: ToastLevel.check,
    message: '기본 언어 ($langDisplay) 설정 및 태그 리빌딩 완료',
  );
}

class _MessageSearchSettingTile extends StatelessWidget {
  final VoidCallback onReload;

  const _MessageSearchSettingTile({required this.onReload});

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatCount(int n) {
    final s = n.toString();
    return s.replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  Future<void> _handleToggle(BuildContext context, bool turnOn) async {
    final mgr = MessageCorpusManager.instance;
    if (turnOn) {
      final existing = await mgr.findInstalledFscmFiles();
      if (existing.isNotEmpty) {
        final ok = await mgr.enableAndDownload();
        if (ok) {
          await Settings.inViewerMessageSearch.setValue(true);
          showToast(
            level: ToastLevel.check,
            message: '한국어 대사 검색 엔진이 활성화되었습니다.',
          );
        }
        onReload();
        return;
      }

      if (!context.mounted) return;
      final ramMb = MessageCorpusManager.getDeviceTotalRamMb();
      final autoBudget = MessageCorpusManager.resolveRecommendedBudgetMb();
      final ramLabel = ramMb > 0
          ? '${(ramMb / 1024).toStringAsFixed(1)} GB'
          : '자동 감지';
      final remoteInfoFuture = mgr.checkRemoteInfo();

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('한국어 대사 레코드 다운로드'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '한국어 작품 전용 대사 레코드를 내려받아 기기 내 Rust 엔진으로 대사를 검색합니다.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.45),
                    ),
                  ),
                  child: FutureBuilder<RemoteCorpusInfo?>(
                    future: remoteInfoFuture,
                    builder: (context, snap) {
                      final info = snap.data;
                      final sizeText = (info != null && info.compressedBytes > 0)
                          ? _formatBytes(info.compressedBytes)
                          : '약 368 MB';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 18,
                                color: Colors.orange,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                snap.connectionState == ConnectionState.waiting
                                    ? '다운로드 용량 확인 중...'
                                    : '다운로드 용량 안내 ($sizeText)',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '다운로드 크기: $sizeText (.7z 단일 압축)\n'
                            '설치 시 기기 내 약 900 MB의 저장 공간을 사용합니다.\n'
                            '모바일 데이터 소모에 유의하시고 Wi-Fi 환경에서 진행해 주세요.',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '기기 메모리($ramLabel)에 맞춰 검색 메모리 예산(${autoBudget}MB)이 자동 선택됩니다.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx, false);
                await Settings.messageSearchMemoryBudgetMb.setValue(autoBudget);
                final ok = await mgr.pickAndInstallLocalFile();
                if (ok) {
                  await Settings.inViewerMessageSearch.setValue(true);
                  showToast(
                    level: ToastLevel.check,
                    message: '로컬 한국어 대사 레코드 설치 및 활성화 완료!',
                  );
                } else {
                  await Settings.enableMessageSearch.setValue(false);
                }
                onReload();
              },
              child: const Text('로컬 파일 불러오기'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Settings.majorColor.value,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('다운로드 및 활성화'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;
      await Settings.messageSearchMemoryBudgetMb.setValue(autoBudget);
      final ok = await mgr.enableAndDownload();
      if (ok) {
        await Settings.inViewerMessageSearch.setValue(true);
        showToast(
          level: ToastLevel.check,
          message: '한국어 대사 레코드 설치 및 엔진 활성화 완료!',
        );
      } else {
        await Settings.enableMessageSearch.setValue(false);
      }
      onReload();
    } else {
      final existing = await mgr.findInstalledFscmFiles();
      bool deleteFiles = false;
      if (existing.isNotEmpty && context.mounted) {
        final action = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('한국어 대사 검색 비활성화'),
            content: const Text('다운로드된 한국어 대사 레코드 파일도 함께 삭제할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'keep'),
                child: const Text('파일 유지'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('파일 삭제 및 끄기'),
              ),
            ],
          ),
        );
        if (action == null || action == 'cancel') return;
        deleteFiles = action == 'delete';
      }
      await mgr.disable(deleteFiles: deleteFiles);
      onReload();
    }
  }

  Widget _buildDeleteCorpusButton(MessageCorpusManager mgr) {
    return TextButton.icon(
      icon: const Icon(
        Icons.delete_outline,
        size: 16,
        color: Colors.redAccent,
      ),
      label: const Text(
        '레코드 삭제',
        style: TextStyle(fontSize: 12, color: Colors.redAccent),
      ),
      onPressed: () async {
        await mgr.disable(deleteFiles: true);
        showToast(
          level: ToastLevel.check,
          message: '한국어 대사 레코드 파일이 삭제되었습니다.',
        );
        onReload();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mgr = MessageCorpusManager.instance;
    return ListenableBuilder(
      listenable: mgr,
      builder: (context, _) {
        final prog = mgr.progress;
        final enabled = Settings.enableMessageSearch.value;
        String subtitleText;
        if (mgr.isBusy) {
          if (prog.state == CorpusInstallState.downloading &&
              prog.totalBytes > 0) {
            final pct =
                (prog.receivedBytes * 100 / prog.totalBytes).clamp(0, 100);
            final spd = _formatBytes(prog.speedBytesPerSec.round());
            subtitleText =
                '${prog.message} ${pct.toStringAsFixed(1)}% (${_formatBytes(prog.receivedBytes)} / ${_formatBytes(prog.totalBytes)}, $spd/s)';
          } else {
            subtitleText = prog.message;
          }
        } else if (enabled && prog.state == CorpusInstallState.ready) {
          final latestPart = mgr.maxArticleId > 0
              ? ' · 최신 품번 #${_formatCount(mgr.maxArticleId)}'
              : '';
          subtitleText =
              '활성화됨 · 대사 ${_formatCount(mgr.recordCount)}건$latestPart (${_formatBytes(mgr.localBytes)}) · 예산 ${Settings.messageSearchMemoryBudgetMb.value}MB';
        } else if (prog.state == CorpusInstallState.error) {
          subtitleText = prog.message;
        } else {
          subtitleText =
              '필요할 때만 한국어 대사 레코드(.7z)를 받아 기기 내에서 대사를 검색합니다.';
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                MdiIcons.commentSearchOutline,
                color: Settings.majorColor.value,
              ),
              title: const Text('경량 대사 검색 엔진'),
              subtitle: Text(
                subtitleText,
                style: TextStyle(
                  fontSize: 12,
                  color: prog.state == CorpusInstallState.error
                      ? Colors.redAccent
                      : null,
                ),
              ),
              trailing: mgr.isBusy
                  ? TextButton(
                      onPressed: mgr.cancelDownload,
                      child: const Text('취소'),
                    )
                  : Switch(
                      value: enabled,
                      onChanged: (v) => _handleToggle(context, v),
                      activeTrackColor: Settings.majorColor.value,
                      activeThumbColor: Settings.majorAccentColor.value,
                    ),
            ),
            if (mgr.isBusy)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: LinearProgressIndicator(
                  value: (prog.state == CorpusInstallState.downloading &&
                          prog.totalBytes > 0)
                      ? (prog.receivedBytes / prog.totalBytes).clamp(0.0, 1.0)
                      : null,
                  color: Settings.majorColor.value,
                ),
              ),
            if (prog.state == CorpusInstallState.error && !mgr.isBusy)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text(
                        '로컬 파일 불러오기',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () async {
                        final ok = await mgr.pickAndInstallLocalFile();
                        if (ok) {
                          await Settings.inViewerMessageSearch.setValue(true);
                          showToast(
                            level: ToastLevel.check,
                            message: '로컬 한국어 대사 레코드 설치 및 활성화 완료!',
                          );
                        }
                        onReload();
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('다시 시도', style: TextStyle(fontSize: 12)),
                      onPressed: () => _handleToggle(context, true),
                    ),
                    if (!enabled) _buildDeleteCorpusButton(mgr),
                  ],
                ),
              ),
            if (enabled && !mgr.isBusy)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 16),
                      label:
                          const Text('레코드 업데이트', style: TextStyle(fontSize: 12)),
                      onPressed: () async {
                        final ok = await mgr.enableAndDownload(force: true);
                        if (ok) {
                          showToast(
                            level: ToastLevel.check,
                            message: '한국어 대사 레코드가 최신 상태로 갱신되었습니다.',
                          );
                        }
                        onReload();
                      },
                    ),
                    _buildDeleteCorpusButton(mgr),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
