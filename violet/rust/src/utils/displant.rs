// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Two-set Korean keyboard (두벌식 영타) <-> Hangul bidirectional converter & search typo restorer.
//! Ported from `project-violet/violet/violet-message-search/src/displant.rs`.

static INDEX_LETTER_FSCM: &[&str] = &[
    "r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fe", "fv", "fg", "a",
    "q", "Q", "qt", "t", "T", "d", "w", "W", "", "z", "e", "v", "g", "k", "o", "i", "O", "j", "p",
    "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l", " ", "ss",
    "se", "st", " ", "frt", "fe", "fqt", " ", "fg", "aq", "at", " ", " ", "qr", "qe", "qtr", "qte",
    "qw", "qe", " ", " ", "tr", "ts", "te", "tq", "tw", " ", "dd", "d", "dt", " ", " ", "gg", " ",
    "yi", "yO", "yl", "bu", "bP", "bl",
];

static INDEX_LETTER_LOSSLESS: &[&str] = &[
    "r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a",
    "q", "Q", "qt", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g", "k", "o", "i", "O", "j", "p",
    "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l",
];

static INDEX_INITIAL_2: &[&str] = &[
    "r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g",
];

static INDEX_MEDIAL_2: &[&str] = &[
    "k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b",
    "m", "ml", "l",
];

static INDEX_FINAL_FSCM: &[&str] = &[
    "", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a",
    "q", "qt", "t", "T", "d", "w", "", "z", "x", "v", "g",
];

static INDEX_FINAL_LOSSLESS: &[&str] = &[
    "", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a",
    "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g",
];

const INITIAL_JAMO: [char; 19] = [
    'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ',
    'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

const VALID_SEARCH_PREFIXES: &[&str] = &[
    "female", "male", "tag", "lang", "language", "series", "artist", "group",
    "uploader", "character", "type", "class", "id", "date", "published", "page",
    "order", "random",
];

#[derive(Debug)]
struct HangulJamo {
    initial: u32,
    medial: u32,
    final_: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenAnalysis {
    pub original: String,
    pub normalized_prefix: Option<String>,
    pub raw_value: String,
    pub restored_hangul: Option<String>,
    pub disassembled_key: String,
    pub restored_expression: Option<String>,
}

pub struct HangulConverter;

impl HangulConverter {
    #[inline]
    fn distortion(ch: u32) -> HangulJamo {
        let unis = ch - 0xAC00;
        HangulJamo {
            initial: unis / (21 * 28),
            medial: (unis % (21 * 28)) / 28,
            final_: (unis % (21 * 28)) % 28,
        }
    }

    #[inline]
    pub fn is_hangul_syllable(ch: char) -> bool {
        ('\u{AC00}'..='\u{D7A3}').contains(&ch)
    }

    #[inline]
    pub fn is_compatibility_jamo(ch: char) -> bool {
        ('\u{3131}'..='\u{3163}').contains(&ch)
    }

    fn push_disassembly_with_tables(
        ch: u32,
        letter_table: &[&str],
        final_table: &[&str],
        buffer: &mut String,
    ) -> bool {
        if (0xAC00..=0xD7A3).contains(&ch) {
            let jamo = Self::distortion(ch);
            buffer.push_str(INDEX_INITIAL_2[jamo.initial as usize]);
            buffer.push_str(INDEX_MEDIAL_2[jamo.medial as usize]);
            buffer.push_str(final_table[jamo.final_ as usize]);
            true
        } else if (0x3131..=0x3163).contains(&ch) {
            if let Some(letter) = letter_table.get((ch - 0x3131) as usize) {
                buffer.push_str(letter);
                true
            } else {
                false
            }
        } else if (0x1100..=0x1112).contains(&ch) {
            if let Some(letter) = INDEX_INITIAL_2.get((ch - 0x1100) as usize) {
                buffer.push_str(letter);
                true
            } else {
                false
            }
        } else if (0x1161..=0x1175).contains(&ch) {
            if let Some(letter) = INDEX_MEDIAL_2.get((ch - 0x1161) as usize) {
                buffer.push_str(letter);
                true
            } else {
                false
            }
        } else if (0x11A8..=0x11C2).contains(&ch) {
            if let Some(letter) = final_table.get((ch - 0x11A7) as usize) {
                buffer.push_str(letter);
                true
            } else {
                false
            }
        } else {
            false
        }
    }

    /// Upstream `.fscm` search key encoder (matches `total_disassembly` in `violet-message-search`).
    pub fn total_disassembly(what: &str) -> String {
        let mut buffer = String::with_capacity(what.len());
        for ch in what.chars() {
            if !Self::push_disassembly_with_tables(
                ch as u32,
                INDEX_LETTER_FSCM,
                INDEX_FINAL_FSCM,
                &mut buffer,
            ) {
                buffer.push(ch);
            }
        }
        buffer
    }

    /// Lossless Hangul -> two-set QWERTY disassembly (preserves ㅊ="c" and standalone ㅌ="x").
    pub fn lossless_disassembly(what: &str) -> String {
        let mut buffer = String::with_capacity(what.len());
        for ch in what.chars() {
            if !Self::push_disassembly_with_tables(
                ch as u32,
                INDEX_LETTER_LOSSLESS,
                INDEX_FINAL_LOSSLESS,
                &mut buffer,
            ) {
                buffer.push(ch);
            }
        }
        buffer
    }

    /// Best-effort inverse of two-set keyboard text (ported 1:1 from `violet-message-search/src/displant.rs`).
    pub fn keyboard_to_hangul(text: &str) -> String {
        fn longest(text: &str, table: &[&str]) -> Option<(usize, usize)> {
            table
                .iter()
                .enumerate()
                .filter(|(_, key)| !key.is_empty() && text.starts_with(**key))
                .map(|(index, key)| (index, key.len()))
                .max_by_key(|(_, len)| *len)
        }

        let mut output = String::with_capacity(text.len());
        let mut rest = text;
        while !rest.is_empty() {
            if let Some((initial, initial_len)) = longest(rest, INDEX_INITIAL_2) {
                if let Some((medial, medial_len)) = longest(&rest[initial_len..], INDEX_MEDIAL_2) {
                    let tail = &rest[initial_len + medial_len..];
                    let (final_, final_len) = INDEX_FINAL_LOSSLESS
                        .iter()
                        .enumerate()
                        .filter(|(_, key)| !key.is_empty() && tail.starts_with(**key))
                        .filter(|(_, key)| longest(&tail[key.len()..], INDEX_MEDIAL_2).is_none())
                        .map(|(index, key)| (index, key.len()))
                        .max_by_key(|(_, len)| *len)
                        .unwrap_or((0, 0));
                    output.push(
                        char::from_u32(
                            0xAC00 + ((initial * 21 + medial) * 28 + final_) as u32,
                        )
                        .unwrap(),
                    );
                    rest = &tail[final_len..];
                } else {
                    output.push(INITIAL_JAMO[initial]);
                    rest = &rest[initial_len..];
                }
            } else if let Some((medial, len)) = longest(rest, INDEX_MEDIAL_2) {
                output.push(char::from_u32(0x314F + medial as u32).unwrap());
                rest = &rest[len..];
            } else {
                let ch = rest.chars().next().unwrap();
                output.push(ch);
                rest = &rest[ch.len_utf8()..];
            }
        }
        output
    }

    /// 영문 알파벳 입력이 실제 한국어 단어의 영타 오타인지 고정밀 판별하여 복원합니다.
    pub fn try_restore_korean_word(value: &str) -> Option<String> {
        if value.is_empty() || !value.chars().any(|c| c.is_ascii_alphabetic()) {
            return None;
        }
        let normalized_ascii: String = value
            .chars()
            .map(|c| match c {
                'R' | 'E' | 'Q' | 'T' | 'W' | 'O' | 'P' => c,
                _ if c.is_ascii_uppercase() => c.to_ascii_lowercase(),
                _ => c,
            })
            .collect();

        let converted = Self::keyboard_to_hangul(&normalized_ascii);
        if converted == value {
            return None;
        }

        let mut syllable_count = 0usize;
        for ch in converted.chars() {
            if Self::is_compatibility_jamo(ch) {
                return None;
            }
            if Self::is_hangul_syllable(ch) {
                syllable_count += 1;
            }
        }
        (syllable_count > 0).then_some(converted)
    }

    pub fn analyze_token(token: &str) -> TokenAnalysis {
        let trimmed = token.trim();
        if trimmed.is_empty() {
            return TokenAnalysis {
                original: String::new(),
                normalized_prefix: None,
                raw_value: String::new(),
                restored_hangul: None,
                disassembled_key: String::new(),
                restored_expression: None,
            };
        }

        let (neg_sign, core) = if let Some(stripped) = trimmed.strip_prefix('-') {
            ("-", stripped)
        } else {
            ("", trimmed)
        };

        if let Some(op_idx) = core.find(['>', '<', '=']) {
            let lhs = &core[..op_idx];
            let rhs = &core[op_idx..];
            let lhs_ascii = Self::lossless_disassembly(lhs).to_ascii_lowercase();
            if matches!(lhs_ascii.as_str(), "page" | "id" | "date" | "published") {
                let rhs_ascii = Self::lossless_disassembly(rhs);
                let expr = format!("{neg_sign}{lhs_ascii}{rhs_ascii}");
                let restored_expr = (expr != trimmed).then_some(expr);
                return TokenAnalysis {
                    original: trimmed.to_string(),
                    normalized_prefix: Some(lhs_ascii),
                    raw_value: rhs_ascii,
                    restored_hangul: None,
                    disassembled_key: Self::lossless_disassembly(trimmed),
                    restored_expression: restored_expr,
                };
            }
        }

        if let Some(colon_idx) = core.find(':') {
            let raw_prefix = &core[..colon_idx];
            let raw_val = &core[colon_idx + 1..];
            let candidate_prefix = Self::lossless_disassembly(raw_prefix).to_ascii_lowercase();

            if VALID_SEARCH_PREFIXES.contains(&candidate_prefix.as_str()) {
                let is_numeric_or_enum = matches!(
                    candidate_prefix.as_str(),
                    "page" | "id" | "date" | "published" | "lang" | "language" | "type" | "class"
                );
                let restored_hangul = if is_numeric_or_enum {
                    None
                } else {
                    Self::try_restore_korean_word(raw_val)
                };
                let val_for_expr = if is_numeric_or_enum {
                    Self::lossless_disassembly(raw_val)
                } else {
                    raw_val.to_string()
                };
                let rebuilt = format!("{neg_sign}{candidate_prefix}:{val_for_expr}");
                let restored_expression = (rebuilt != trimmed).then_some(rebuilt);

                return TokenAnalysis {
                    original: trimmed.to_string(),
                    normalized_prefix: Some(candidate_prefix),
                    raw_value: raw_val.to_string(),
                    restored_hangul,
                    disassembled_key: Self::lossless_disassembly(raw_val),
                    restored_expression,
                };
            }
        }

        let dis = Self::lossless_disassembly(core);
        let dis_lower = dis.to_ascii_lowercase();
        let restored_expression =
            if dis_lower != core && VALID_SEARCH_PREFIXES.contains(&dis_lower.as_str()) {
                Some(format!("{neg_sign}{dis_lower}"))
            } else {
                None
            };

        TokenAnalysis {
            original: trimmed.to_string(),
            normalized_prefix: None,
            raw_value: core.to_string(),
            restored_hangul: Self::try_restore_korean_word(core),
            disassembled_key: dis,
            restored_expression,
        }
    }

    pub fn normalize_query_typos(query: &str) -> String {
        if query.trim().is_empty() {
            return query.to_string();
        }
        let mut out = Vec::new();
        for raw_tok in query.split_whitespace() {
            let leading_parens: String = raw_tok.chars().take_while(|&c| c == '(').collect();
            let trailing_parens: String = raw_tok
                .chars()
                .rev()
                .take_while(|&c| c == ')')
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            let start = leading_parens.len();
            let end = raw_tok.len().saturating_sub(trailing_parens.len());
            if start >= end {
                out.push(raw_tok.to_string());
                continue;
            }
            let inner = &raw_tok[start..end];
            let inner_dis = Self::lossless_disassembly(inner);
            if inner != "or" && inner != "OR" && inner_dis.eq_ignore_ascii_case("or") {
                out.push(format!("{leading_parens}or{trailing_parens}"));
                continue;
            }
            let analysis = Self::analyze_token(inner);
            if let Some(expr) = analysis.restored_expression {
                out.push(format!("{leading_parens}{expr}{trailing_parens}"));
            } else {
                out.push(raw_tok.to_string());
            }
        }
        out.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::HangulConverter;

    #[test]
    fn restores_keyboard_text_and_syllable_boundaries() {
        for text in [
            "안녕하세요", "값이", "읽고", "읽어", "앉아", "없다", "괜찮아", "까꿍", "쐐기",
            "의외", "각사", "가나", "안녕! 123", "ㄱㅏ",
        ] {
            let encoded = HangulConverter::total_disassembly(text);
            let expected = if text == "ㄱㅏ" { "가" } else { text };
            assert_eq!(HangulConverter::keyboard_to_hangul(&encoded), expected, "{encoded}");
        }
        assert_eq!(HangulConverter::keyboard_to_hangul("rkcl"), "가치");
        assert_eq!(HangulConverter::keyboard_to_hangul("rkc!"), "갗!");
    }

    #[test]
    fn lossless_roundtrips_all_11172_hangul_syllables() {
        for code in 0xAC00..=0xD7A3 {
            let text = char::from_u32(code).unwrap().to_string();
            let key = HangulConverter::lossless_disassembly(&text);
            assert_eq!(HangulConverter::keyboard_to_hangul(&key), text);
        }
    }

    #[test]
    fn smart_token_restoration_distinguishes_korean_typo_from_english() {
        let t1 = HangulConverter::analyze_token("ㄹ드미ㄷ:dpfvm");
        assert_eq!(t1.normalized_prefix.as_deref(), Some("female"));
        assert_eq!(t1.restored_hangul.as_deref(), Some("엘프"));
        assert_eq!(t1.restored_expression.as_deref(), Some("female:dpfvm"));

        let t2 = HangulConverter::analyze_token("ㅔㅁㅎㄷ>=120");
        assert_eq!(t2.restored_expression.as_deref(), Some("page>=120"));

        assert_eq!(HangulConverter::try_restore_korean_word("sole_female"), None);
        assert_eq!(HangulConverter::try_restore_korean_word("loli"), None);
        assert_eq!(
            HangulConverter::try_restore_korean_word("eksehrdutjd").as_deref(),
            Some("단독여성")
        );
    }
}