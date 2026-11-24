// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:violet/pages/settings/settings_widgets.dart';
import 'package:violet/settings/settings.dart';

List<Widget> buildTranslationGroup(
  BuildContext context,
  VoidCallback reload,
) {
  return [
    const SettingGroupName(name: '번역'),
    buildSettingItems([
      InkWell(
        customBorder: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8.0)),
        ),
        child: ListTile(
          leading: Icon(MdiIcons.translate, color: Settings.majorColor.value),
          title: const Text('자동번역'),
          subtitle: const Text('한국어가 아닌 작품 열람 시 자동으로 번역합니다'),
          trailing: Switch(
            value: Settings.autoTranslate.value,
            onChanged: (newValue) async {
              await Settings.autoTranslate.setValue(newValue);
              reload();
            },
            activeTrackColor: Settings.majorColor.value,
            activeThumbColor: Settings.majorAccentColor.value,
          ),
        ),
        onTap: () async {
          await Settings.autoTranslate.setValue(!Settings.autoTranslate.value);
          reload();
        },
      ),
    ]),
  ];
}
