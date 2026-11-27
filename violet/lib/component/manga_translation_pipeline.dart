// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

import 'dart:typed_data';

import 'package:violet/src/rust/api/manga_vision.dart' as rust_vision;
import 'package:violet/src/rust/api/translation.dart' as rust_tx;

/// Phase 2: Violet 프로덕션용 Rust FFI 통합 만화 번역 파이프라인
/// - 1채널 흑백 전처리, 테두리 흰색 비율 필터링, Zero-AI 글자 지우기,
///   MangaNormalizer/Glossary 치환을 단일 Rust FFI 소스로 처리합니다.
class MangaTranslationPipeline {
  static final MangaTranslationPipeline instance =
      MangaTranslationPipeline._internal();
  MangaTranslationPipeline._internal();

  /// 1단계: 1채널 그레이스케일 전처리 및 리사이징
  Future<rust_vision.PreprocessedMangaPage?> preprocessGrayscale(
    Uint8List imageBytes, {
    int maxLongEdge = 1280,
  }) {
    return rust_vision.preprocessMangaGrayscale(
      bytes: imageBytes,
      maxLongEdge: maxLongEdge,
    );
  }

  /// 2단계: 박스 외곽 테두리 밝기 히스토그램 기반 말풍선 필터링 (배경/효과음 제거)
  Future<List<rust_vision.FilteredBubbleResult>> filterSpeechBubbles({
    required Uint8List lumaBytes,
    required int width,
    required int height,
    required List<rust_vision.TextBoxInput> boxes,
    int borderPx = 3,
    double minWhiteRatio = 0.75,
    bool allowInverted = true,
  }) {
    return rust_vision.filterSpeechBubbles(
      lumaBytes: lumaBytes,
      width: width,
      height: height,
      boxes: boxes,
      borderPx: borderPx,
      minWhiteRatio: minWhiteRatio,
      allowInverted: allowInverted,
    );
  }

  /// 3단계: Zero-AI Connected Components 기반 고속 글자 지우기
  Future<rust_vision.ZeroAiEraseResult?> eraseBubbleTextZeroAi({
    required Uint8List lumaBytes,
    required int width,
    required int height,
    required List<rust_vision.BubbleEraseRegion> regions,
    int dilationPx = 2,
  }) {
    return rust_vision.eraseBubbleTextZeroAi(
      lumaBytes: lumaBytes,
      width: width,
      height: height,
      regions: regions,
      dilationPx: dilationPx,
    );
  }

  /// 4단계: Rust 단일 소스 일본어 정규화 + 용어집 치환 + 배치 번역/후처리
  String normalizeJapanese(String raw) =>
      rust_tx.normalizeJapaneseSync(text: raw);

  String applyGlossary(
    String text,
    List<rust_tx.GlossaryEntry> glossary,
  ) =>
      rust_tx.applyMangaGlossarySync(text: text, glossary: glossary);

  rust_tx.MangaPageTranslationReport translateJapaneseBatch(
    List<String> texts,
  ) =>
      rust_tx.translateMangaJapaneseBatchSync(texts: texts);

  String polishKorean(String translatedKo, String originalJa) =>
      rust_tx.polishKoreanTranslationSync(
        translatedKo: translatedKo,
        originalJa: originalJa,
      );
}
