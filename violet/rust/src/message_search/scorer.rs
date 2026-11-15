// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Pure-Rust RapidFuzz scorer matching `violet-message-search/src/binding.rs` (`0.0..=100.0` scale).

use memchr::memmem::Finder;
use rapidfuzz::distance::indel::{Args, BatchComparator};

pub trait SimilarityMethod: Sync {
    fn exact_similarity(&self, _message: &str) -> Option<f64> {
        None
    }

    fn exact_matches_dominate_fuzzy(&self) -> bool {
        false
    }

    fn similarity(&self, message: &str, score_cutoff: f64) -> f64;
}

#[inline]
fn build_byte_hist(bytes: &[u8]) -> [u16; 256] {
    let mut hist = [0u16; 256];
    for &b in bytes {
        hist[b as usize] = hist[b as usize].saturating_add(1);
    }
    hist
}

#[inline]
fn common_multiset_bytes(q_hist: &[u16; 256], q_mask: &[u64; 4], other: &[u8]) -> usize {
    let mut rem = *q_hist;
    let mut common = 0usize;
    for &b in other {
        if has_byte(q_mask, b) {
            let slot = &mut rem[b as usize];
            if *slot > 0 {
                *slot -= 1;
                common += 1;
            }
        }
    }
    common
}

pub struct CachedRatio {
    comparator: BatchComparator<u8>,
    q_len: usize,
    q_mask: [u64; 4],
    q_hist: [u16; 256],
}

impl CachedRatio {
    pub fn from_query(query: &str) -> Self {
        let qb = query.as_bytes();
        Self {
            comparator: BatchComparator::new(qb.iter().copied()),
            q_len: qb.len(),
            q_mask: build_byte_mask(qb),
            q_hist: build_byte_hist(qb),
        }
    }
}

impl SimilarityMethod for CachedRatio {
    fn similarity(&self, message: &str, score_cutoff: f64) -> f64 {
        let m = message.as_bytes();
        if self.q_len == 0 && m.is_empty() {
            return if score_cutoff <= 100.0 { 100.0 } else { 0.0 };
        }
        if self.q_len == 0 || m.is_empty() || score_cutoff > 100.0 {
            return 0.0;
        }
        let cutoff_norm = (score_cutoff / 100.0).clamp(0.0, 1.0);
        let denom = self.q_len + m.len();
        let min_len = self.q_len.min(m.len());
        if (2 * min_len) as f64 / (denom as f64) + 1e-12 < cutoff_norm {
            return 0.0;
        }
        let common = common_multiset_bytes(&self.q_hist, &self.q_mask, m);
        if common == 0 || (2 * common) as f64 / (denom as f64) + 1e-12 < cutoff_norm {
            return 0.0;
        }
        let args = Args::default().score_cutoff(cutoff_norm);
        self.comparator
            .normalized_similarity_with_args(m.iter().copied(), &args)
            .map_or(0.0, |v| v * 100.0)
    }
}

#[inline]
fn build_byte_mask(bytes: &[u8]) -> [u64; 4] {
    let mut m = [0u64; 4];
    for &b in bytes {
        m[(b >> 6) as usize] |= 1u64 << (b & 63);
    }
    m
}

#[inline]
fn has_byte(mask: &[u64; 4], b: u8) -> bool {
    (mask[(b >> 6) as usize] & (1u64 << (b & 63))) != 0
}

fn slide_partial_windows(
    cmp: &BatchComparator<u8>,
    mask: &[u64; 4],
    len1: usize,
    long: &[u8],
    initial_cutoff: f64,
) -> f64 {
    let len2 = long.len();
    let mut cutoff = initial_cutoff;
    let mut best = 0.0f64;

    for i in 1..len1 {
        if !has_byte(mask, long[i - 1]) {
            continue;
        }
        let args = Args::default().score_cutoff(cutoff);
        if let Some(s) = cmp.normalized_similarity_with_args(long[..i].iter().copied(), &args) {
            if s > best {
                best = s;
                cutoff = cutoff.max(best);
            }
        }
    }

    for i in 0..=(len2 - len1) {
        if !has_byte(mask, long[i]) && !has_byte(mask, long[i + len1 - 1]) {
            continue;
        }
        let args = Args::default().score_cutoff(cutoff);
        if let Some(s) =
            cmp.normalized_similarity_with_args(long[i..i + len1].iter().copied(), &args)
        {
            if s > best {
                best = s;
                if (best - 1.0).abs() < f64::EPSILON {
                    return 100.0;
                }
                cutoff = cutoff.max(best);
            }
        }
    }

    for i in 1..len1 {
        let start = len2 - i;
        if !has_byte(mask, long[start]) {
            continue;
        }
        let args = Args::default().score_cutoff(cutoff);
        if let Some(s) = cmp.normalized_similarity_with_args(long[start..].iter().copied(), &args) {
            if s > best {
                best = s;
                cutoff = cutoff.max(best);
            }
        }
    }

    best * 100.0
}

pub struct CachedPartialRatio {
    comparator: BatchComparator<u8>,
    finder: Finder<'static>,
    query: String,
    mask: [u64; 4],
    hist: [u16; 256],
}

impl CachedPartialRatio {
    pub fn from_query(query: &str) -> Self {
        let qb = query.as_bytes();
        Self {
            comparator: BatchComparator::new(qb.iter().copied()),
            finder: Finder::new(qb).into_owned(),
            mask: build_byte_mask(qb),
            hist: build_byte_hist(qb),
            query: query.to_string(),
        }
    }
}

impl SimilarityMethod for CachedPartialRatio {
    fn exact_matches_dominate_fuzzy(&self) -> bool {
        true
    }

    #[inline]
    fn exact_similarity(&self, message: &str) -> Option<f64> {
        if !self.query.is_empty() && self.finder.find(message.as_bytes()).is_some() {
            Some(100.0)
        } else {
            None
        }
    }

    fn similarity(&self, message: &str, score_cutoff: f64) -> f64 {
        let q = self.query.as_bytes();
        let m = message.as_bytes();
        if q.is_empty() && m.is_empty() {
            return if score_cutoff <= 100.0 { 100.0 } else { 0.0 };
        }
        if q.is_empty() || m.is_empty() || score_cutoff > 100.0 {
            return 0.0;
        }
        let cutoff = (score_cutoff / 100.0).clamp(0.0, 1.0);
        let common = common_multiset_bytes(&self.hist, &self.mask, m);
        if common == 0 {
            return 0.0;
        }
        let short_len = q.len().min(m.len());
        if (2 * common) as f64 / ((short_len + common) as f64) + 1e-12 < cutoff {
            return 0.0;
        }
        if q.len() <= m.len() {
            if self.finder.find(m).is_some() {
                return 100.0;
            }
            slide_partial_windows(&self.comparator, &self.mask, q.len(), m, cutoff)
        } else {
            if self.query.contains(message) {
                return 100.0;
            }
            let short_cmp = BatchComparator::new(m.iter().copied());
            let short_mask = build_byte_mask(m);
            slide_partial_windows(&short_cmp, &short_mask, m.len(), q, cutoff)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{CachedPartialRatio, CachedRatio, SimilarityMethod};

    fn ratio(src: &str, tar: &str) -> usize {
        CachedRatio::from_query(src).similarity(tar, 0.0) as usize
    }

    fn partial(src: &str, tar: &str) -> usize {
        CachedPartialRatio::from_query(src).similarity(tar, 0.0) as usize
    }

    #[test]
    fn cached_ratio_matches_upstream_rapidfuzz_cpp() {
        assert_eq!(ratio("abcd", "abcd"), 100);
        assert_eq!(ratio("abcd", "abcde"), 88);
        assert_eq!(ratio("abcde", "abcd"), 88);
        assert_eq!(ratio("abcd", "acbd"), 75);
        assert_eq!(ratio("abcd", "efgh"), 0);

        let scorer = CachedRatio::from_query("abcd");
        assert_eq!(scorer.similarity("abcde", 88.0) as usize, 88);
        assert_eq!(scorer.similarity("abcde", 89.0) as usize, 0);
    }

    #[test]
    fn cached_partial_ratio_matches_upstream_rapidfuzz_cpp() {
        assert_eq!(partial("abcd", "abcd"), 100);
        assert_eq!(partial("abcd", "abcde"), 100);
        assert_eq!(partial("abcde", "abcd"), 100);
        assert_eq!(partial("abcd", "acbd"), 75);
        assert_eq!(partial("abcdefg", "cbedgf"), 54);
        assert_eq!(partial("abcd", "efgh"), 0);

        let scorer = CachedPartialRatio::from_query("abcd");
        assert_eq!(scorer.exact_similarity("xxabcdyy"), Some(100.0));
        assert_eq!(scorer.exact_similarity("acbd"), None);
        assert_eq!(scorer.similarity("acbd", 75.0) as usize, 75);
        assert_eq!(scorer.similarity("acbd", 76.0) as usize, 0);
    }
}