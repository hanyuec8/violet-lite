// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

/// 다중 작품 번호 입력 파싱 결과입니다.
class DownloadIdParseResult {
  final List<String> validIds;
  final List<String> duplicateInputIds;
  final List<String> invalidTokens;

  const DownloadIdParseResult({
    required this.validIds,
    required this.duplicateInputIds,
    required this.invalidTokens,
  });

  bool get isEmpty => validIds.isEmpty && invalidTokens.isEmpty;
  bool get hasErrors => invalidTokens.isNotEmpty;
}

/// 쉼표, 공백, 줄바꿈으로 구분된 작품 번호 문자열을 파싱하고 중복 및 오타를 검증합니다.
DownloadIdParseResult parseDownloadIds(String rawInput) {
  final tokens = rawInput
      .split(RegExp(r'[\s,]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty);

  final validIds = <String>[];
  final seen = <String>{};
  final duplicateInputIds = <String>[];
  final invalidTokens = <String>[];
  final digitPattern = RegExp(r'^\d+$');

  for (final token in tokens) {
    if (!digitPattern.hasMatch(token)) {
      invalidTokens.add(token);
      continue;
    }
    if (!seen.add(token)) {
      duplicateInputIds.add(token);
      continue;
    }
    validIds.add(token);
  }

  return DownloadIdParseResult(
    validIds: validIds,
    duplicateInputIds: duplicateInputIds,
    invalidTokens: invalidTokens,
  );
}
