// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Native title clustering and multilingual title matching via `rapidfuzz` + Union-Find.

use ahash::AHashMap;
use rapidfuzz::distance::levenshtein;
use rayon::prelude::*;

#[flutter_rust_bridge::frb(ignore)]
struct DisjointSet {
    parent: Vec<usize>,
}

impl DisjointSet {
    fn new(n: usize) -> Self {
        Self {
            parent: (0..n).collect(),
        }
    }

    fn find(&mut self, mut x: usize) -> usize {
        while self.parent[x] != x {
            self.parent[x] = self.parent[self.parent[x]];
            x = self.parent[x];
        }
        x
    }

    fn union(&mut self, a: usize, b: usize) {
        let ra = self.find(a);
        let rb = self.find(b);
        if ra != rb {
            self.parent[rb] = ra;
        }
    }
}

fn prepare_cluster_chars(title: &str) -> Vec<u32> {
    let cleaned = title.trim().replace("(decensored)", "");
    let first_part = cleaned.split('|').next().unwrap_or("");
    first_part.chars().map(|c| c as u32).collect()
}

fn cluster_titles_inner(titles: &[String]) -> Vec<Vec<u32>> {
    let n = titles.len();
    if n == 0 {
        return Vec::new();
    }

    let max_node = n.min(100);
    let prepared: Vec<Vec<u32>> = titles.iter().map(|t| prepare_cluster_chars(t)).collect();

    let compute_neighbors = |i: usize| -> Vec<u32> {
        let a = &prepared[i];
        let cmp = levenshtein::BatchComparator::new(a.iter().copied());
        let args = levenshtein::Args::default().score_cutoff(8);
        let mut hits: Vec<(usize, u32)> = Vec::new();

        for (j, b) in prepared.iter().enumerate() {
            if a.len().abs_diff(b.len()) > 8 {
                continue;
            }
            if let Some(d) = cmp.distance_with_args(b.iter().copied(), &args) {
                if d <= 8 {
                    hits.push((d, j as u32));
                }
            }
        }

        if hits.len() > max_node {
            hits.sort_unstable_by(|x, y| x.0.cmp(&y.0).then(x.1.cmp(&y.1)));
            hits.truncate(max_node);
        }
        let mut idxs: Vec<u32> = hits.into_iter().map(|(_, idx)| idx).collect();
        idxs.sort_unstable();
        idxs
    };

    let neighbor_lists: Vec<Vec<u32>> = if n >= 32 {
        (0..n).into_par_iter().map(compute_neighbors).collect()
    } else {
        (0..n).map(compute_neighbors).collect()
    };

    let mut by_group: AHashMap<Vec<u32>, Vec<u32>> = AHashMap::new();
    for list in neighbor_lists {
        by_group.entry(list).or_default();
    }

    let mut ds = DisjointSet::new(n);
    for group in by_group.keys() {
        if let Some(&first) = group.first() {
            for &member in &group[1..] {
                ds.union(first as usize, member as usize);
            }
        }
    }

    let mut joined: AHashMap<usize, Vec<u32>> = AHashMap::new();
    let mut order: Vec<usize> = Vec::new();
    for i in 0..n {
        let root = ds.find(i);
        let entry = joined.entry(root).or_insert_with(|| {
            order.push(root);
            Vec::new()
        });
        entry.push(i as u32);
    }

    order
        .into_iter()
        .filter_map(|root| joined.remove(&root))
        .collect()
}

/// 백그라운드 스레드풀에서 제목 리스트를 Levenshtein 거리(<=8) 기반으로 클러스터링합니다.
pub fn cluster_titles(titles: Vec<String>) -> Vec<Vec<u32>> {
    cluster_titles_inner(&titles)
}

#[flutter_rust_bridge::frb(sync)]
pub fn cluster_titles_sync(titles: Vec<String>) -> Vec<Vec<u32>> {
    cluster_titles_inner(&titles)
}

fn strip_bracket_group(s: &str, open: char, close: char) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == open {
            let mut found_close = false;
            let mut buf = String::new();
            for nc in chars.by_ref() {
                if nc == close {
                    found_close = true;
                    break;
                }
                buf.push(nc);
            }
            if found_close {
                out.push(' ');
            } else {
                out.push(open);
                out.push_str(&buf);
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[inline]
fn is_title_keep_char(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || ('가'..='힣').contains(&c)
        || ('\u{3040}'..='\u{30ff}').contains(&c)
        || ('\u{4e00}'..='\u{9faf}').contains(&c)
}

pub(crate) fn normalize_title_inner(raw: &str) -> String {
    let s1 = strip_bracket_group(raw, '[', ']');
    let s2 = strip_bracket_group(&s1, '(', ')');
    let s3 = strip_bracket_group(&s2, '{', '}');
    s3.to_lowercase()
        .chars()
        .filter(|&c| is_title_keep_char(c))
        .collect()
}

pub(crate) fn extract_title_tokens_inner(raw: &str) -> Vec<String> {
    if raw.trim().is_empty() {
        return Vec::new();
    }
    let mut seen = Vec::new();
    let mut push_unique = |tok: String| {
        if tok.chars().count() >= 3 && !seen.contains(&tok) {
            seen.push(tok);
        }
    };

    // '|', '/', ' - ' 분리
    let mut rest = raw;
    while !rest.is_empty() {
        let next_pipe = rest.find('|');
        let next_slash = rest.find('/');
        let next_dash = rest.find(" - ");
        let split_pos = [
            next_pipe.map(|p| (p, 1usize)),
            next_slash.map(|p| (p, 1usize)),
            next_dash.map(|p| (p, 3usize)),
        ]
        .into_iter()
        .flatten()
        .min_by_key(|x| x.0);

        match split_pos {
            Some((idx, sep_len)) => {
                push_unique(normalize_title_inner(&rest[..idx]));
                rest = &rest[idx + sep_len..];
            }
            None => {
                push_unique(normalize_title_inner(rest));
                break;
            }
        }
    }

    push_unique(normalize_title_inner(raw));
    seen
}

pub(crate) fn is_title_matched_inner(raw_a: &str, raw_b: &str) -> bool {
    if raw_a.is_empty() || raw_b.is_empty() {
        return false;
    }
    let full_a = normalize_title_inner(raw_a);
    let full_b = normalize_title_inner(raw_b);
    let len_a = full_a.chars().count();
    let len_b = full_b.chars().count();
    if len_a >= 3 && full_a == full_b {
        return true;
    }
    let tokens_a = extract_title_tokens_inner(raw_a);
    let tokens_b = extract_title_tokens_inner(raw_b);
    if len_a >= 5 && tokens_b.contains(&full_a) {
        return true;
    }
    if len_b >= 5 && tokens_a.contains(&full_b) {
        return true;
    }
    false
}

#[flutter_rust_bridge::frb(sync)]
pub fn normalize_title_sync(raw: String) -> String {
    normalize_title_inner(&raw)
}

#[flutter_rust_bridge::frb(sync)]
pub fn extract_title_tokens_sync(raw: String) -> Vec<String> {
    extract_title_tokens_inner(&raw)
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_title_matched_sync(raw_a: String, raw_b: String) -> bool {
    is_title_matched_inner(&raw_a, &raw_b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clusters_similar_titles_and_matches_multilingual_variants() {
        let titles = vec![
            "Winter Story Vol.1".to_string(),
            "Winter Story Vol.2".to_string(),
            "Completely Different Work".to_string(),
        ];
        let clusters = cluster_titles_inner(&titles);
        assert_eq!(clusters.len(), 2);
        assert_eq!(clusters[0], vec![0, 1]);
        assert_eq!(clusters[1], vec![2]);

        let base = "Usugoori no Kanojo-tachi | 살얼음의 그녀들 (decensored)";
        let en = "[Dendoro Kakariya] Usugoori no Kanojo-tachi [English] [Digital]";
        assert!(is_title_matched_inner(base, en));
        assert!(!is_title_matched_inner(base, "Unrelated Title"));
    }
}
