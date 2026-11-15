// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

use crate::utils::displant::HangulConverter;

#[derive(Debug, Clone)]
pub struct RestoredSearchToken {
    pub original: String,
    pub normalized_prefix: Option<String>,
    pub raw_value: String,
    pub restored_hangul: Option<String>,
    pub disassembled_key: String,
    pub restored_expression: Option<String>,
}

/// 두벌식 영타 키열을 완성형 한글로 복원합니다 (예: "dkssudgktpdy" -> "안녕하세요").
#[flutter_rust_bridge::frb(sync)]
pub fn restore_hangul_typo(input: String) -> String {
    HangulConverter::keyboard_to_hangul(&input)
}

/// 한글 문자열을 무손실 두벌식 영타로 분해합니다 (예: "빛" -> "qlc").
#[flutter_rust_bridge::frb(sync)]
pub fn disassemble_hangul_lossless(input: String) -> String {
    HangulConverter::lossless_disassembly(&input)
}

/// 검색 토큰 하나를 분석하여 한타 프리픽스/연산식 및 영타 한글 오타 복원 후보를 추출합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn analyze_search_token(token: String) -> RestoredSearchToken {
    let analyzed = HangulConverter::analyze_token(&token);
    RestoredSearchToken {
        original: analyzed.original,
        normalized_prefix: analyzed.normalized_prefix,
        raw_value: analyzed.raw_value,
        restored_hangul: analyzed.restored_hangul,
        disassembled_key: analyzed.disassembled_key,
        restored_expression: analyzed.restored_expression,
    }
}

/// 복합 검색 쿼리에서 명백한 한타 프리픽스/연산식 오타(예: "ㄹ드미ㄷ:dpfvm ㅔㅁㅎㄷ>100")를 정규화합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn normalize_search_query_typos(query: String) -> String {
    HangulConverter::normalize_query_typos(&query)
}