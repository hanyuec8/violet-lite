// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Parallel batch article filtering engine mirroring `LocalArticleFilter`.

use rayon::prelude::*;

#[derive(Debug, Clone)]
pub struct FilterArticleInput {
    pub id: Option<i64>,
    pub files: Option<i32>,
    pub title: String,
    pub artists: String,
    pub groups: String,
    pub series: String,
    pub characters: String,
    pub tags: String,
    pub language: String,
    pub article_type: String,
    pub classname: String,
    pub uploader: String,
}

#[derive(Debug, Clone)]
pub struct FilterTokenInput {
    pub page_op: Option<String>,
    pub page_count: Option<i32>,
    pub min_page_range: Option<i32>,
    pub max_page_range: Option<i32>,
    pub is_id_condition: bool,
    pub field: Option<String>,
    pub value: String,
    pub restored_korean_value: Option<String>,
    pub translated_match_keys: Vec<String>,
    pub negative: bool,
}

#[inline]
fn normalize_val(v: &str) -> String {
    v.to_lowercase().replace('_', " ")
}

#[inline]
fn split_pipe_contains(raw: &str, needle: &str) -> bool {
    if raw.is_empty() {
        return false;
    }
    raw.split('|')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .any(|item| item.to_lowercase().contains(needle))
}

fn split_pipe_matches_with_keys(
    raw: &str,
    default_cls: &str,
    needle: &str,
    translated_keys: &[String],
    require_prefix: Option<&str>,
) -> bool {
    if raw.is_empty() {
        return false;
    }
    for part in raw.split('|').map(str::trim).filter(|s| !s.is_empty()) {
        let lower = part.to_lowercase();
        if let Some(pfx) = require_prefix {
            if !lower.starts_with(pfx) {
                continue;
            }
        }
        if lower.contains(needle) {
            return true;
        }
        if !translated_keys.is_empty() {
            let full_key = if lower.contains(':') {
                lower.clone()
            } else {
                format!("{default_cls}:{lower}")
            };
            if translated_keys.iter().any(|k| k == &full_key || k == &lower) {
                return true;
            }
        }
    }
    false
}

/// `Settings.matchesIdRule`와 동일한 ID 필터 규칙 판별.
pub(crate) fn matches_id_rule(article_id: i64, raw_rule: &str) -> bool {
    let mut rule = raw_rule.trim().to_lowercase();
    if let Some(rest) = rule.strip_prefix('-') {
        rule = rest.trim().to_string();
    }
    if rule.is_empty() {
        return false;
    }
    if let Ok(plain) = rule.parse::<i64>() {
        return article_id == plain;
    }
    if let Some(target) = rule.strip_prefix("id:") {
        for part in target.trim().split(',') {
            let p = part.trim();
            if p.is_empty() {
                continue;
            }
            if let Some((a, b)) = split_id_range(p) {
                let lo = a.min(b);
                let hi = a.max(b);
                if article_id >= lo && article_id <= hi {
                    return true;
                }
            } else if let Ok(single) = p.parse::<i64>() {
                if article_id == single {
                    return true;
                }
            }
        }
        return false;
    }
    if let Some(rest) = rule.strip_prefix("id") {
        for op in [">=", "<=", "==", "!=", ">", "<", "="] {
            if let Some(num_str) = rest.strip_prefix(op) {
                if let Ok(val) = num_str.parse::<i64>() {
                    return match op {
                        ">" => article_id > val,
                        ">=" => article_id >= val,
                        "<" => article_id < val,
                        "<=" => article_id <= val,
                        "=" | "==" => article_id == val,
                        "!=" => article_id != val,
                        _ => false,
                    };
                }
            }
        }
    }
    false
}

fn split_id_range(p: &str) -> Option<(i64, i64)> {
    for sep in ["..", "~", "-"] {
        if let Some((left, right)) = p.split_once(sep) {
            if let (Ok(a), Ok(b)) = (left.parse::<i64>(), right.parse::<i64>()) {
                return Some((a, b));
            }
        }
    }
    None
}

fn matches_page_op(op: &str, pages: i32, count: i32) -> bool {
    match op {
        ">" => pages > count,
        ">=" => pages >= count,
        "<" => pages < count,
        "<=" => pages <= count,
        "=" | "==" => pages == count,
        _ => false,
    }
}

fn matches_field_or_text(
    article: &FilterArticleInput,
    field: Option<&str>,
    target_val: &str,
    translated_keys: &[String],
) -> bool {
    let norm = normalize_val(target_val);

    if let Some(f) = field {
        return match f {
            "artist" => split_pipe_contains(&article.artists, &norm),
            "series" => split_pipe_matches_with_keys(
                &article.series,
                "series",
                &norm,
                translated_keys,
                None,
            ),
            "character" => split_pipe_matches_with_keys(
                &article.characters,
                "character",
                &norm,
                translated_keys,
                None,
            ),
            "group" => split_pipe_contains(&article.groups, &norm),
            "tag" => split_pipe_matches_with_keys(
                &article.tags,
                "tag",
                &norm,
                translated_keys,
                None,
            ),
            "male" => split_pipe_matches_with_keys(
                &article.tags,
                "tag",
                &norm,
                translated_keys,
                Some("male:"),
            ),
            "female" => split_pipe_matches_with_keys(
                &article.tags,
                "tag",
                &norm,
                translated_keys,
                Some("female:"),
            ),
            "lang" => article.language.to_lowercase().contains(&norm),
            "type" => article.article_type.to_lowercase().contains(&norm),
            "class" => article.classname.to_lowercase().contains(&norm),
            "uploader" => article.uploader.to_lowercase().contains(&norm),
            _ => false,
        };
    }

    if article.title.to_lowercase().contains(&norm) {
        return true;
    }
    if article.id.is_some_and(|id| id.to_string() == norm) {
        return true;
    }
    if split_pipe_contains(&article.artists, &norm) {
        return true;
    }
    if split_pipe_contains(&article.groups, &norm) {
        return true;
    }
    if split_pipe_matches_with_keys(&article.series, "series", &norm, translated_keys, None) {
        return true;
    }
    if split_pipe_matches_with_keys(&article.characters, "character", &norm, translated_keys, None) {
        return true;
    }
    split_pipe_matches_with_keys(&article.tags, "tag", &norm, translated_keys, None)
}

fn matches_token(article: &FilterArticleInput, token: &FilterTokenInput) -> bool {
    if token.is_id_condition {
        let Some(id) = article.id else {
            return token.negative;
        };
        let ok = matches_id_rule(id, &token.value);
        return if token.negative { !ok } else { ok };
    }

    if token.page_op.is_some() || token.min_page_range.is_some() || token.max_page_range.is_some() {
        let Some(pages) = article.files else {
            return false;
        };
        let ok = if let (Some(op), Some(cnt)) = (token.page_op.as_deref(), token.page_count) {
            matches_page_op(op, pages, cnt)
        } else {
            let min_ok = token.min_page_range.is_none_or(|m| pages >= m);
            let max_ok = token.max_page_range.is_none_or(|m| pages <= m);
            min_ok && max_ok
        };
        return if token.negative { !ok } else { ok };
    }

    let raw_match = matches_field_or_text(
        article,
        token.field.as_deref(),
        &token.value,
        &token.translated_match_keys,
    ) || token.restored_korean_value.as_deref().is_some_and(|kor| {
        matches_field_or_text(
            article,
            token.field.as_deref(),
            kor,
            &token.translated_match_keys,
        )
    });

    if token.negative {
        !raw_match
    } else {
        raw_match
    }
}

fn article_matches_all(
    article: &FilterArticleInput,
    tokens: &[FilterTokenInput],
    min_pages: Option<i32>,
    max_pages: Option<i32>,
) -> bool {
    if min_pages.is_some() || max_pages.is_some() {
        let Some(pages) = article.files else {
            return false;
        };
        if min_pages.is_some_and(|m| pages < m) || max_pages.is_some_and(|m| pages > m) {
            return false;
        }
    }
    tokens.iter().all(|t| matches_token(article, t))
}

/// 파싱된 토큰 조건으로 작품 리스트를 병렬 필터링하여 일치하는 인덱스(`u32`)를 반환합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn filter_articles_batch_sync(
    articles: Vec<FilterArticleInput>,
    tokens: Vec<FilterTokenInput>,
    min_pages: Option<i32>,
    max_pages: Option<i32>,
) -> Vec<u32> {
    if articles.len() >= 128 {
        articles
            .par_iter()
            .enumerate()
            .filter_map(|(idx, article)| {
                article_matches_all(article, &tokens, min_pages, max_pages).then_some(idx as u32)
            })
            .collect()
    } else {
        articles
            .iter()
            .enumerate()
            .filter_map(|(idx, article)| {
                article_matches_all(article, &tokens, min_pages, max_pages).then_some(idx as u32)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_articles() -> Vec<FilterArticleInput> {
        vec![
            FilterArticleInput {
                id: Some(101),
                files: Some(24),
                title: "Short Elf Story".to_string(),
                artists: "|nishi|".to_string(),
                groups: String::new(),
                series: String::new(),
                characters: String::new(),
                tags: "|female:elf|female:sole female|".to_string(),
                language: "korean".to_string(),
                article_type: "doujinshi".to_string(),
                classname: String::new(),
                uploader: String::new(),
            },
            FilterArticleInput {
                id: Some(102),
                files: Some(60),
                title: "Medium Anthology".to_string(),
                artists: "|alpha|".to_string(),
                groups: String::new(),
                series: String::new(),
                characters: String::new(),
                tags: "|full color|".to_string(),
                language: "korean".to_string(),
                article_type: "manga".to_string(),
                classname: String::new(),
                uploader: String::new(),
            },
        ]
    }

    #[test]
    fn filters_page_id_and_translated_tags_accurately() {
        let articles = sample_articles();
        let page_tok = FilterTokenInput {
            page_op: Some("<=".to_string()),
            page_count: Some(30),
            min_page_range: None,
            max_page_range: None,
            is_id_condition: false,
            field: None,
            value: "page<=30".to_string(),
            restored_korean_value: None,
            translated_match_keys: Vec::new(),
            negative: false,
        };
        assert_eq!(
            filter_articles_batch_sync(articles.clone(), vec![page_tok], None, None),
            vec![0]
        );

        let id_neg = FilterTokenInput {
            page_op: None,
            page_count: None,
            min_page_range: None,
            max_page_range: None,
            is_id_condition: true,
            field: None,
            value: "id:101".to_string(),
            restored_korean_value: None,
            translated_match_keys: Vec::new(),
            negative: true,
        };
        assert_eq!(
            filter_articles_batch_sync(articles.clone(), vec![id_neg], None, None),
            vec![1]
        );

        let kor_tag = FilterTokenInput {
            page_op: None,
            page_count: None,
            min_page_range: None,
            max_page_range: None,
            is_id_condition: false,
            field: Some("tag".to_string()),
            value: "엘프".to_string(),
            restored_korean_value: None,
            translated_match_keys: vec!["female:elf".to_string()],
            negative: false,
        };
        assert_eq!(
            filter_articles_batch_sync(articles, vec![kor_tag], None, None),
            vec![0]
        );
    }
}
