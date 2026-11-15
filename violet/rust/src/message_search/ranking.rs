// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Full-corpus exact/fuzzy top-k ranking over bounded blocks.
//! Ported from `project-violet/violet/violet-message-search/src/message/mobile/ranking.rs`.

use std::io;
use std::sync::atomic::Ordering as AtomicOrdering;

use super::mobile::{popular_rank_lookup, MobileStore, Scope};
use super::scorer::SimilarityMethod;
use super::{
    collect_exact_results_triple, collect_fuzzy_results_triple_with_cutoff, ScoredMessage,
    StoredMessage, TopScoredTriple,
};

pub struct RankedTriple {
    pub total_matched: u64,
    pub relevance: Vec<ScoredMessage>,
    pub latest: Vec<ScoredMessage>,
    pub popular: Vec<ScoredMessage>,
}

impl MobileStore {
    pub(crate) fn rank_all(
        &self,
        scope: &Scope,
        scorer: impl SimilarityMethod,
        minimum_message_bytes: usize,
        take: usize,
    ) -> io::Result<RankedTriple> {
        let take = take.clamp(1, 10_000);
        let mut best = TopScoredTriple::new(take);
        let filter = |m: &StoredMessage<'_>| {
            scope.includes(m.article_id) && m.message.len() >= minimum_message_bytes
        };
        let popular_map = popular_rank_lookup();
        let rank_lookup = |aid: u32| -> u32 {
            popular_map.get(&aid).copied().unwrap_or(u32::MAX)
        };

        let prefer_exact_matches = scorer.exact_matches_dominate_fuzzy();

        if prefer_exact_matches {
            self.scan_scoped(scope, |first_record, block| {
                self.pool.install(|| {
                    let block_hits = collect_exact_results_triple(
                        block,
                        &scorer,
                        &filter,
                        &rank_lookup,
                        take,
                    );
                    merge_triple_hits(&mut best, block_hits, first_record);
                });
                Ok(())
            })?;

            // 정확한 부분 문자열 일치가 0건일 때만 유사도 폴백 스캔 수행
            if best.matched_count == 0 {
                self.scanned.store(0, AtomicOrdering::Relaxed);
                self.scan_scoped(scope, |first_record, block| {
                    self.pool.install(|| {
                        let cutoff = best.min_cutoff().max(65.0);
                        let block_hits = collect_fuzzy_results_triple_with_cutoff(
                            block,
                            &scorer,
                            &filter,
                            &rank_lookup,
                            take,
                            true,
                            cutoff,
                        );
                        merge_triple_hits(&mut best, block_hits, first_record);
                    });
                    Ok(())
                })?;
            }
        } else {
            self.scan_scoped(scope, |first_record, block| {
                self.pool.install(|| {
                    let cutoff = best.min_cutoff().max(50.0);
                    let block_hits = collect_fuzzy_results_triple_with_cutoff(
                        block,
                        &scorer,
                        &filter,
                        &rank_lookup,
                        take,
                        false,
                        cutoff,
                    );
                    merge_triple_hits(&mut best, block_hits, first_record);
                });
                Ok(())
            })?;
        }

        self.planned.store(
            self.scanned.load(AtomicOrdering::Relaxed),
            AtomicOrdering::Relaxed,
        );
        let total_matched = best.matched_count;
        Ok(RankedTriple {
            total_matched,
            relevance: best.rel.into_sorted_vec(),
            latest: best.lat.into_sorted_vec(),
            popular: best.pop.into_sorted_vec(),
        })
    }
}

fn merge_triple_hits(
    best: &mut TopScoredTriple,
    block_hits: TopScoredTriple,
    first_record: usize,
) {
    best.matched_count = best.matched_count.saturating_add(block_hits.matched_count);
    for mut hit in block_hits.rel.into_sorted_vec() {
        hit.index += first_record;
        best.rel.push_scored(hit);
    }
    for mut hit in block_hits.lat.into_sorted_vec() {
        hit.index += first_record;
        best.lat.push_scored(hit);
    }
    for mut hit in block_hits.pop.into_sorted_vec() {
        hit.index += first_record;
        best.pop.push_scored(hit);
    }
}