// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter/foundation.dart';

/// Phase 5: 기기 등급별 온디바이스 번역 실행 프로파일
enum DeviceTranslationTier {
  /// RAM 4~6GB 구형/보급형 기기 (발열/OOM 방지: 2스레드, 1280px, 경량 NMT)
  lowRamLegacy,

  /// 최신 플래그십 CPU 전용 (Galaxy S25 등: 4스레드, 1600px, 안정성 최우선)
  flagshipCpu,

  /// 최신 플래그십 NPU 가속 (LiteRT/QNN EP 우선, 미지원 시 CPU 자동 폴백)
  flagshipNpu,
}

class DeviceTranslationProfile {
  final DeviceTranslationTier tier;
  final int maxLongEdge;
  final int numThreads;
  final int maxCachedPages;
  final bool preferLightweightNmt;
  final bool useNpuIfAvailable;

  const DeviceTranslationProfile({
    required this.tier,
    required this.maxLongEdge,
    required this.numThreads,
    required this.maxCachedPages,
    required this.preferLightweightNmt,
    required this.useNpuIfAvailable,
  });

  static const DeviceTranslationProfile lowRamLegacy = DeviceTranslationProfile(
    tier: DeviceTranslationTier.lowRamLegacy,
    maxLongEdge: 1280,
    numThreads: 2,
    maxCachedPages: 6,
    preferLightweightNmt: true,
    useNpuIfAvailable: false,
  );

  static const DeviceTranslationProfile flagshipCpu = DeviceTranslationProfile(
    tier: DeviceTranslationTier.flagshipCpu,
    maxLongEdge: 1600,
    numThreads: 4,
    maxCachedPages: 12,
    preferLightweightNmt: false,
    useNpuIfAvailable: false,
  );

  static const DeviceTranslationProfile flagshipNpu = DeviceTranslationProfile(
    tier: DeviceTranslationTier.flagshipNpu,
    maxLongEdge: 1600,
    numThreads: 4,
    maxCachedPages: 12,
    preferLightweightNmt: false,
    useNpuIfAvailable: true,
  );

  static DeviceTranslationProfile fromName(
    String name, {
    bool useNpu = false,
  }) {
    if (name == 'lowRamLegacy') return lowRamLegacy;
    if (name == 'flagshipNpu' || useNpu) return flagshipNpu;
    return flagshipCpu;
  }
}

/// Phase 5: 실기기 6구간 밀리초(ms) 프로파일링 기록
class MangaTranslationStageTiming {
  final int pageIndex;
  final double preprocessMs;
  final double ocrDetectMs;
  final double ocrRecMs;
  final double zeroAiEraseMs;
  final double translateMs;
  final double typesetMs;

  const MangaTranslationStageTiming({
    required this.pageIndex,
    required this.preprocessMs,
    required this.ocrDetectMs,
    required this.ocrRecMs,
    required this.zeroAiEraseMs,
    required this.translateMs,
    required this.typesetMs,
  });

  double get totalMs =>
      preprocessMs +
      ocrDetectMs +
      ocrRecMs +
      zeroAiEraseMs +
      translateMs +
      typesetMs;

  void logSummary() {
    debugPrint(
      '[MangaTxProfiler] page=$pageIndex '
      'prep=${preprocessMs.toStringAsFixed(1)}ms, '
      'det=${ocrDetectMs.toStringAsFixed(1)}ms, '
      'rec=${ocrRecMs.toStringAsFixed(1)}ms, '
      'erase=${zeroAiEraseMs.toStringAsFixed(1)}ms, '
      'tx=${translateMs.toStringAsFixed(1)}ms, '
      'typeset=${typesetMs.toStringAsFixed(1)}ms '
      '(total=${totalMs.toStringAsFixed(1)}ms)',
    );
  }
}
