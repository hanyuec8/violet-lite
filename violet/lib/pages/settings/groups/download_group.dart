// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:violet/downloader/isolate_downloader.dart';
import 'package:violet/locale/locale.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/settings/settings_widgets.dart';
import 'package:violet/settings/settings.dart';

List<Widget> buildDownloadGroup(
  BuildContext context,
  VoidCallback reload,
) {
  final isAndroid = Platform.isAndroid;

  return [
    SettingGroupName(name: Translations.instance!.trans('download')),
    buildSettingItems([
      if (isAndroid)
        InkWell(
          customBorder: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(8.0),
              topRight: Radius.circular(8.0),
            ),
          ),
          child: ListTile(
            leading: Icon(
              MdiIcons.cellphoneArrowDown,
              color: Settings.majorColor.value,
            ),
            title: const Text('앱 내부 저장소 사용'),
            subtitle: const Text('별도 저장소 권한 없이 앱 전용 폴더에 안전하게 저장합니다'),
            trailing: Switch(
              value: Settings.useInnerStorage.value,
              onChanged: (newValue) async {
                await Settings.useInnerStorage.setValue(newValue);
                reload();
              },
              activeTrackColor: Settings.majorColor.value,
              activeThumbColor: Settings.majorAccentColor.value,
            ),
          ),
          onTap: () async {
            await Settings.useInnerStorage.setValue(
              !Settings.useInnerStorage.value,
            );
            reload();
          },
        ),
      if (!isAndroid || !Settings.useInnerStorage.value)
        ListTile(
          leading: Icon(
            MdiIcons.folderDownloadOutline,
            color: Settings.majorColor.value,
          ),
          title: Text(Translations.instance!.trans('downloadpath')),
          subtitle: Text(
            Settings.downloadBasePath.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.keyboard_arrow_right),
          onTap: () async {
            final selected = await FilePicker.platform.getDirectoryPath();
            if (selected != null && selected.isNotEmpty) {
              await Settings.downloadBasePath.setValue(selected);
              reload();
              showToast(
                level: ToastLevel.check,
                message: '다운로드 경로를 변경했습니다.',
              );
            }
          },
        ),
      ListTile(
        leading: Icon(
          MdiIcons.fileCogOutline,
          color: Settings.majorColor.value,
        ),
        title: Text(Translations.instance!.trans('downloadrule')),
        subtitle: Text(
          Settings.downloadRule.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.keyboard_arrow_right),
        onTap: () async {
          final controller = TextEditingController(
            text: Settings.downloadRule.value,
          );
          final saved = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(Translations.instance!.trans('downloadrule')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: '파일 저장 규칙',
                      hintText: '%(extractor)s/%(id)s/%(file)s.%(ext)s',
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '사용 가능 변수: %(extractor)s, %(id)s, %(title)s, %(artist)s, %(group)s, %(file)s, %(ext)s',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(
                    ctx,
                    '%(extractor)s/%(id)s/%(file)s.%(ext)s',
                  ),
                  child: const Text('기본값'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('취소'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Settings.majorColor.value,
                  ),
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('저장'),
                ),
              ],
            ),
          );
          if (saved != null && saved.isNotEmpty) {
            await Settings.downloadRule.setValue(saved);
            reload();
          }
        },
      ),
      InkWell(
        customBorder: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(8.0),
            bottomRight: Radius.circular(8.0),
          ),
        ),
        child: ListTile(
          leading: Icon(
            MdiIcons.speedometer,
            color: Settings.majorColor.value,
          ),
          title: const Text('동시 다운로드 스레드 수'),
          subtitle: Text('${Settings.threadCount.value}개 동시 다운로드'),
          trailing: const Icon(Icons.keyboard_arrow_right),
          onTap: () async {
            int current = Settings.threadCount.value.clamp(1, 16);
            final selected = await showDialog<int>(
              context: context,
              builder: (ctx) => StatefulBuilder(
                builder: (ctx, setModalState) => AlertDialog(
                  title: const Text('동시 다운로드 스레드 수'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$current개',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Slider(
                        value: current.toDouble(),
                        min: 1,
                        max: 16,
                        divisions: 15,
                        label: '$current',
                        onChanged: (v) => setModalState(() => current = v.round()),
                      ),
                    ],
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
                      onPressed: () => Navigator.pop(ctx, current),
                      child: const Text('저장'),
                    ),
                  ],
                ),
              ),
            );
            if (selected != null) {
              await Settings.threadCount.setValue(selected);
              final downloader = await IsolateDownloader.getInstance();
              downloader.changeThreadCount(selected);
              reload();
            }
          },
        ),
      ),
    ]),
  ];
}
