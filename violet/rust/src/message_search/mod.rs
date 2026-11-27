// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Core FSCM binary structures, query normalization, and top-k min-heap ranking.
//! Ported from `project-violet/violet/violet-message-search/src/message.rs`.

use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

use rayon::prelude::*;

use crate::utils::displant::HangulConverter;
use scorer::SimilarityMethod;

pub mod mobile;
pub mod ranking;
pub mod scan;
pub mod scorer;
pub mod source;

pub const FLAT_MAGIC: &[u8; 8] = b"FSCMMSG1";
pub const FLAT_VERSION: u32 = 1;
pub const FLAT_FLAG_RAW: u32 = 1;
pub const FLAT_RECORD_LEN: usize = 52;
pub const HEADER_LEN: u64 = 32;

pub const FLAT_V2_MAGIC: &[u8; 8] = b"FSCMMSG2";
pub const FLAT_V2_VERSION: u32 = 2;
pub const V2_FLAG_LZ4_HOT: u32 = 1;
pub const V2_FLAG_LZ4_COLD: u32 = 2;
pub const V2_HEADER_LEN: u64 = 32;
pub const V2_ARTICLE_ENTRY_LEN: usize = 12;
pub const V2_BLOCK_ENTRY_LEN: usize = 48;
pub const V2_DEFAULT_BLOCK_RECORDS: usize = 16_384;

pub fn invalid_data(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

#[inline]
pub fn convert_query(query: &str) -> String {
    let clean: String = query.chars().filter(|c| !c.is_whitespace()).collect();
    HangulConverter::total_disassembly(&clean)
}

#[inline]
pub fn response_text(raw: Option<&str>, encoded_message: &str) -> String {
    match raw {
        Some(text) if !text.is_empty() => text.to_string(),
        _ => HangulConverter::keyboard_to_hangul(encoded_message),
    }
}

#[derive(Clone, Copy, Debug)]
pub struct TextRange {
    pub offset: u64,
    pub len: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct MessageMeta {
    pub article_id: u32,
    pub page: u32,
    pub message: TextRange,
    pub correct: f32,
    pub rects: [f32; 4],
}

#[derive(Default)]
pub struct MessageBlock {
    pub messages: Vec<MessageMeta>,
    pub message_bytes: Vec<u8>,
}

pub struct StoredMessage<'a> {
    pub article_id: u32,
    pub page: u32,
    pub message: &'a str,
    pub correct: f32,
    pub rects: [f32; 4],
}

impl MessageBlock {
    /// Returns a safely-validated slice view for `index`, returning `None` if the
    /// index, byte range, or UTF-8 sequence is invalid.
    #[inline]
    pub fn try_get(&self, index: usize) -> Option<StoredMessage<'_>> {
        let meta = self.messages.get(index)?;
        let start = usize::try_from(meta.message.offset).ok()?;
        let end = start.checked_add(meta.message.len as usize)?;
        let slice = self.message_bytes.get(start..end)?;
        let message = std::str::from_utf8(slice).ok()?;
        Some(StoredMessage {
            article_id: meta.article_id,
            page: meta.page,
            message,
            correct: meta.correct,
            rects: meta.rects,
        })
    }

    #[inline]
    pub fn get(&self, index: usize) -> StoredMessage<'_> {
        if let Some(msg) = self.try_get(index) {
            return msg;
        }
        let meta = &self.messages[index];
        StoredMessage {
            article_id: meta.article_id,
            page: meta.page,
            message: "",
            correct: meta.correct,
            rects: meta.rects,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct FlatRecord {
    pub article_id: u32,
    pub page: u32,
    pub message_offset: u64,
    pub message_len: u32,
    pub raw_offset: u64,
    pub raw_len: u32,
    pub correct: f32,
    pub rects: [f32; 4],
}

impl FlatRecord {
    pub fn read_from<R: Read>(reader: &mut R) -> io::Result<Self> {
        let mut b = [0u8; FLAT_RECORD_LEN];
        reader.read_exact(&mut b)?;
        Ok(Self {
            article_id: u32::from_le_bytes(b[0..4].try_into().unwrap()),
            page: u32::from_le_bytes(b[4..8].try_into().unwrap()),
            message_offset: u64::from_le_bytes(b[8..16].try_into().unwrap()),
            message_len: u32::from_le_bytes(b[16..20].try_into().unwrap()),
            raw_offset: u64::from_le_bytes(b[20..28].try_into().unwrap()),
            raw_len: u32::from_le_bytes(b[28..32].try_into().unwrap()),
            correct: f32::from_bits(u32::from_le_bytes(b[32..36].try_into().unwrap())),
            rects: [
                f32::from_bits(u32::from_le_bytes(b[36..40].try_into().unwrap())),
                f32::from_bits(u32::from_le_bytes(b[40..44].try_into().unwrap())),
                f32::from_bits(u32::from_le_bytes(b[44..48].try_into().unwrap())),
                f32::from_bits(u32::from_le_bytes(b[48..52].try_into().unwrap())),
            ],
        })
    }

    pub fn write_to<W: Write>(&self, writer: &mut W) -> io::Result<()> {
        let mut b = [0u8; FLAT_RECORD_LEN];
        b[0..4].copy_from_slice(&self.article_id.to_le_bytes());
        b[4..8].copy_from_slice(&self.page.to_le_bytes());
        b[8..16].copy_from_slice(&self.message_offset.to_le_bytes());
        b[16..20].copy_from_slice(&self.message_len.to_le_bytes());
        b[20..28].copy_from_slice(&self.raw_offset.to_le_bytes());
        b[28..32].copy_from_slice(&self.raw_len.to_le_bytes());
        b[32..36].copy_from_slice(&self.correct.to_bits().to_le_bytes());
        b[36..40].copy_from_slice(&self.rects[0].to_bits().to_le_bytes());
        b[40..44].copy_from_slice(&self.rects[1].to_bits().to_le_bytes());
        b[44..48].copy_from_slice(&self.rects[2].to_bits().to_le_bytes());
        b[48..52].copy_from_slice(&self.rects[3].to_bits().to_le_bytes());
        writer.write_all(&b)
    }

    #[inline]
    pub fn validate(&self, arena_bytes: u64) -> io::Result<()> {
        let msg_end = self
            .message_offset
            .checked_add(u64::from(self.message_len))
            .ok_or_else(|| invalid_data("FSCM message range overflow"))?;
        let raw_end = self
            .raw_offset
            .checked_add(u64::from(self.raw_len))
            .ok_or_else(|| invalid_data("FSCM raw range overflow"))?;
        if msg_end > arena_bytes || raw_end > arena_bytes {
            return Err(invalid_data("FSCM text range out of bounds"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum SortMode {
    #[default]
    Relevance = 0,
    Latest = 1,
    Popular = 2,
}

impl SortMode {
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => Self::Latest,
            2 => Self::Popular,
            _ => Self::Relevance,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ScoredMessage {
    pub index: usize,
    pub article_id: u32,
    pub score: f64,
    pub correct: f32,
    pub popular_rank: u32,
}

impl ScoredMessage {
    #[inline]
    pub fn cmp_quality(&self, other: &Self, mode: SortMode) -> Ordering {
        match mode {
            SortMode::Relevance => self
                .score
                .total_cmp(&other.score)
                .then_with(|| self.correct.total_cmp(&other.correct))
                .then_with(|| self.article_id.cmp(&other.article_id))
                .then_with(|| other.index.cmp(&self.index)),
            SortMode::Latest => {
                let s_tier = if self.score >= 99.9 {
                    10u32
                } else {
                    (self.score / 10.0).floor().clamp(0.0, 9.0) as u32
                };
                let o_tier = if other.score >= 99.9 {
                    10u32
                } else {
                    (other.score / 10.0).floor().clamp(0.0, 9.0) as u32
                };
                s_tier
                    .cmp(&o_tier)
                    .then_with(|| self.article_id.cmp(&other.article_id))
                    .then_with(|| self.score.total_cmp(&other.score))
                    .then_with(|| self.correct.total_cmp(&other.correct))
                    .then_with(|| other.index.cmp(&self.index))
            }
            SortMode::Popular => {
                let s_tier = if self.score >= 99.9 {
                    10u32
                } else {
                    (self.score / 10.0).floor().clamp(0.0, 9.0) as u32
                };
                let o_tier = if other.score >= 99.9 {
                    10u32
                } else {
                    (other.score / 10.0).floor().clamp(0.0, 9.0) as u32
                };
                s_tier
                    .cmp(&o_tier)
                    .then_with(|| other.popular_rank.cmp(&self.popular_rank))
                    .then_with(|| self.score.total_cmp(&other.score))
                    .then_with(|| self.article_id.cmp(&other.article_id))
                    .then_with(|| other.index.cmp(&self.index))
            }
        }
    }
}

#[derive(Clone, Copy)]
struct WorstFirst {
    item: ScoredMessage,
    mode: SortMode,
}

impl PartialEq for WorstFirst {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for WorstFirst {}

impl PartialOrd for WorstFirst {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for WorstFirst {
    fn cmp(&self, other: &Self) -> Ordering {
        other.item.cmp_quality(&self.item, self.mode)
    }
}

pub struct TopScoredMessages {
    take: usize,
    mode: SortMode,
    matched_count: u64,
    heap: BinaryHeap<WorstFirst>,
}

impl TopScoredMessages {
    pub fn new(take: usize) -> Self {
        Self::with_mode(take, SortMode::Relevance)
    }

    pub fn with_mode(take: usize, mode: SortMode) -> Self {
        Self {
            take,
            mode,
            matched_count: 0,
            heap: BinaryHeap::with_capacity(take.saturating_add(1)),
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.heap.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.heap.is_empty()
    }

    #[inline]
    pub fn matched_count(&self) -> u64 {
        self.matched_count
    }

    #[inline]
    pub fn score_cutoff(&self) -> f64 {
        if self.take == 0 {
            return f64::INFINITY;
        }
        if self.heap.len() < self.take {
            0.0
        } else {
            let s = self.heap.peek().map_or(0.0, |w| w.item.score);
            match self.mode {
                SortMode::Relevance => s,
                SortMode::Latest | SortMode::Popular => {
                    if s >= 99.9 {
                        99.9
                    } else {
                        (s / 10.0).floor() * 10.0
                    }
                }
            }
        }
    }

    #[inline]
    pub fn push_scored(&mut self, item: ScoredMessage) {
        if item.score <= 0.0 {
            return;
        }
        self.matched_count = self.matched_count.saturating_add(1);
        if self.take == 0 {
            return;
        }
        if self.heap.len() < self.take {
            self.heap.push(WorstFirst { item, mode: self.mode });
        } else if let Some(worst) = self.heap.peek() {
            if item.cmp_quality(&worst.item, self.mode) == Ordering::Greater {
                self.heap.pop();
                self.heap.push(WorstFirst { item, mode: self.mode });
            }
        }
    }

    pub fn merge(mut self, other: Self) -> Self {
        self.matched_count = self.matched_count.saturating_add(other.matched_count);
        for w in other.heap {
            let item = w.item;
            if self.take == 0 || item.score <= 0.0 {
                continue;
            }
            if self.heap.len() < self.take {
                self.heap.push(WorstFirst { item, mode: self.mode });
            } else if let Some(worst) = self.heap.peek() {
                if item.cmp_quality(&worst.item, self.mode) == Ordering::Greater {
                    self.heap.pop();
                    self.heap.push(WorstFirst { item, mode: self.mode });
                }
            }
        }
        self
    }

    pub fn into_sorted_vec(self) -> Vec<ScoredMessage> {
        let mode = self.mode;
        let mut out: Vec<ScoredMessage> = self.heap.into_iter().map(|w| w.item).collect();
        out.sort_unstable_by(|a, b| b.cmp_quality(a, mode));
        out
    }
}

pub struct TopScoredTriple {
    pub rel: TopScoredMessages,
    pub lat: TopScoredMessages,
    pub pop: TopScoredMessages,
    pub matched_count: u64,
}

impl TopScoredTriple {
    pub fn new(take: usize) -> Self {
        Self {
            rel: TopScoredMessages::with_mode(take, SortMode::Relevance),
            lat: TopScoredMessages::with_mode(take, SortMode::Latest),
            pop: TopScoredMessages::with_mode(take, SortMode::Popular),
            matched_count: 0,
        }
    }

    #[inline]
    pub fn push_scored(&mut self, item: ScoredMessage) {
        if item.score <= 0.0 {
            return;
        }
        self.matched_count = self.matched_count.saturating_add(1);
        self.rel.push_scored(item);
        self.lat.push_scored(item);
        self.pop.push_scored(item);
    }

    #[inline]
    pub fn min_cutoff(&self) -> f64 {
        self.rel
            .score_cutoff()
            .min(self.lat.score_cutoff())
            .min(self.pop.score_cutoff())
    }

    pub fn merge(mut self, other: Self) -> Self {
        self.matched_count = self.matched_count.saturating_add(other.matched_count);
        self.rel = self.rel.merge(other.rel);
        self.lat = self.lat.merge(other.lat);
        self.pop = self.pop.merge(other.pop);
        self
    }
}

#[derive(Default)]
struct GlobalScoreCutoff {
    bits: AtomicU64,
}

impl GlobalScoreCutoff {
    #[inline]
    fn get(&self) -> f64 {
        f64::from_bits(self.bits.load(AtomicOrdering::Relaxed))
    }

    #[inline]
    fn publish(&self, score: f64) {
        let mut cur = self.bits.load(AtomicOrdering::Relaxed);
        while score > f64::from_bits(cur) {
            match self.bits.compare_exchange_weak(
                cur,
                score.to_bits(),
                AtomicOrdering::Relaxed,
                AtomicOrdering::Relaxed,
            ) {
                Ok(_) => break,
                Err(actual) => cur = actual,
            }
        }
    }
}

pub fn collect_exact_results_triple<S, F, P>(
    block: &MessageBlock,
    scorer: &S,
    filter: &F,
    rank_lookup: &P,
    take: usize,
) -> TopScoredTriple
where
    S: SimilarityMethod,
    F: Fn(&StoredMessage<'_>) -> bool + Sync,
    P: Fn(u32) -> u32 + Sync,
{
    (0..block.messages.len())
        .into_par_iter()
        .fold(
            || TopScoredTriple::new(take),
            |mut acc, idx| {
                let msg = block.get(idx);
                if filter(&msg) {
                    if let Some(score) = scorer.exact_similarity(msg.message) {
                        acc.push_scored(ScoredMessage {
                            index: idx,
                            article_id: msg.article_id,
                            score,
                            correct: msg.correct,
                            popular_rank: rank_lookup(msg.article_id),
                        });
                    }
                }
                acc
            },
        )
        .reduce(|| TopScoredTriple::new(take), TopScoredTriple::merge)
}

pub fn collect_fuzzy_results_triple_with_cutoff<S, F, P>(
    block: &MessageBlock,
    scorer: &S,
    filter: &F,
    rank_lookup: &P,
    take: usize,
    skip_exact: bool,
    initial_cutoff: f64,
) -> TopScoredTriple
where
    S: SimilarityMethod,
    F: Fn(&StoredMessage<'_>) -> bool + Sync,
    P: Fn(u32) -> u32 + Sync,
{
    let global = GlobalScoreCutoff::default();
    if initial_cutoff > 0.0 {
        global.publish(initial_cutoff);
    }

    (0..block.messages.len())
        .into_par_iter()
        .fold(
            || TopScoredTriple::new(take),
            |mut acc, idx| {
                let msg = block.get(idx);
                if !filter(&msg) {
                    return acc;
                }
                if skip_exact && scorer.exact_similarity(msg.message).is_some() {
                    return acc;
                }
                let cutoff = acc.min_cutoff().max(global.get());
                let score = scorer.similarity(msg.message, cutoff);
                if score > 0.0 && score >= cutoff {
                    acc.push_scored(ScoredMessage {
                        index: idx,
                        article_id: msg.article_id,
                        score,
                        correct: msg.correct,
                        popular_rank: rank_lookup(msg.article_id),
                    });
                    let min_c = acc.min_cutoff();
                    if min_c > 0.0 {
                        global.publish(min_c);
                    }
                }
                acc
            },
        )
        .reduce(|| TopScoredTriple::new(take), TopScoredTriple::merge)
}

#[derive(Default)]
pub struct FlatMessageWriter {
    records: Vec<FlatRecord>,
    arena: Vec<u8>,
    has_raw: bool,
}

impl FlatMessageWriter {
    pub fn push(
        &mut self,
        article_id: u32,
        page: u32,
        encoded_msg: &str,
        raw: Option<&str>,
        correct: f32,
        rects: [f32; 4],
    ) {
        let message_offset = self.arena.len() as u64;
        self.arena.extend_from_slice(encoded_msg.as_bytes());
        let message_len = encoded_msg.len() as u32;
        let (raw_offset, raw_len) = if let Some(r) = raw {
            self.has_raw = true;
            let off = self.arena.len() as u64;
            self.arena.extend_from_slice(r.as_bytes());
            (off, r.len() as u32)
        } else {
            (0, 0)
        };
        self.records.push(FlatRecord {
            article_id,
            page,
            message_offset,
            message_len,
            raw_offset,
            raw_len,
            correct,
            rects,
        });
    }

    pub fn write_to<W: Write>(&self, writer: &mut W) -> io::Result<()> {
        writer.write_all(FLAT_MAGIC)?;
        writer.write_all(&FLAT_VERSION.to_le_bytes())?;
        let flags = if self.has_raw { FLAT_FLAG_RAW } else { 0 };
        writer.write_all(&flags.to_le_bytes())?;
        writer.write_all(&(self.records.len() as u64).to_le_bytes())?;
        writer.write_all(&(self.arena.len() as u64).to_le_bytes())?;
        for rec in &self.records {
            rec.write_to(writer)?;
        }
        writer.write_all(&self.arena)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ArticleEntryV2 {
    pub article_id: u32,
    pub start_record: u32,
    pub record_count: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct BlockEntryV2 {
    pub first_article_id: u32,
    pub last_article_id: u32,
    pub first_record: u32,
    pub record_count: u32,
    pub hot_offset: u64,
    pub hot_len: u32,
    pub hot_raw_len: u32,
    pub cold_offset: u64,
    pub cold_len: u32,
    pub cold_raw_len: u32,
}

#[inline]
pub fn quantize_correct_u8(correct: f32) -> u8 {
    (correct.clamp(0.0, 1.0) * 255.0).round() as u8
}

#[inline]
pub fn dequantize_correct_f32(q: u8) -> f32 {
    f32::from(q) / 255.0
}

#[inline]
pub fn quantize_rects_xywh(rects: [f32; 4]) -> [u16; 4] {
    let x1 = rects[0].round().clamp(0.0, 65535.0) as u16;
    let y1 = rects[1].round().clamp(0.0, 65535.0) as u16;
    let x2 = rects[2].round().clamp(0.0, 65535.0) as u16;
    let y2 = rects[3].round().clamp(0.0, 65535.0) as u16;
    let w = x2.saturating_sub(x1);
    let h = y2.saturating_sub(y1);
    [x1, y1, w, h]
}

#[inline]
pub fn dequantize_rects_xywh(xywh: [u16; 4]) -> [f32; 4] {
    let x1 = f32::from(xywh[0]);
    let y1 = f32::from(xywh[1]);
    let x2 = f32::from(xywh[0].saturating_add(xywh[2]));
    let y2 = f32::from(xywh[1].saturating_add(xywh[3]));
    [x1, y1, x2, y2]
}

struct V2PendingRecord {
    article_id: u32,
    page: u16,
    correct: u8,
    msg: String,
    xywh: [u16; 4],
}

#[derive(Default)]
pub struct FlatMessageWriterV2 {
    records: Vec<V2PendingRecord>,
    lz4_hot: bool,
    lz4_cold: bool,
}

impl FlatMessageWriterV2 {
    pub fn with_compression(lz4_hot: bool, lz4_cold: bool) -> Self {
        Self {
            records: Vec::new(),
            lz4_hot,
            lz4_cold,
        }
    }

    pub fn push(
        &mut self,
        article_id: u32,
        page: u32,
        encoded_msg: &str,
        correct: f32,
        rects: [f32; 4],
    ) {
        self.records.push(V2PendingRecord {
            article_id,
            page: page.min(u32::from(u16::MAX)) as u16,
            correct: quantize_correct_u8(correct),
            msg: encoded_msg.to_string(),
            xywh: quantize_rects_xywh(rects),
        });
    }

    pub fn write_to<W: Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.records
            .sort_unstable_by(|a, b| a.article_id.cmp(&b.article_id).then(a.page.cmp(&b.page)));

        let total_records = self.records.len() as u64;
        let mut articles: Vec<ArticleEntryV2> = Vec::new();
        for (idx, rec) in self.records.iter().enumerate() {
            match articles.last_mut() {
                Some(last) if last.article_id == rec.article_id => last.record_count += 1,
                _ => articles.push(ArticleEntryV2 {
                    article_id: rec.article_id,
                    start_record: idx as u32,
                    record_count: 1,
                }),
            }
        }

        let block_count = if self.records.is_empty() {
            0usize
        } else {
            self.records.len().div_ceil(V2_DEFAULT_BLOCK_RECORDS)
        };
        let mut hot_payloads = Vec::with_capacity(block_count);
        let mut cold_payloads = Vec::with_capacity(block_count);
        let mut blocks = Vec::with_capacity(block_count);

        for chunk_idx in 0..block_count {
            let start = chunk_idx * V2_DEFAULT_BLOCK_RECORDS;
            let end = (start + V2_DEFAULT_BLOCK_RECORDS).min(self.records.len());
            let slice = &self.records[start..end];
            let n = slice.len();

            let mut runs: Vec<(u32, u32)> = Vec::new();
            for rec in slice {
                match runs.last_mut() {
                    Some((aid, cnt)) if *aid == rec.article_id => *cnt += 1,
                    _ => runs.push((rec.article_id, 1)),
                }
            }

            let text_total: usize = slice.iter().map(|r| r.msg.len().min(usize::from(u16::MAX))).sum();
            let mut hot_raw = Vec::with_capacity(4 + runs.len() * 8 + n * 5 + text_total);
            hot_raw.extend_from_slice(&(runs.len() as u32).to_le_bytes());
            for (aid, cnt) in &runs {
                hot_raw.extend_from_slice(&aid.to_le_bytes());
                hot_raw.extend_from_slice(&cnt.to_le_bytes());
            }
            for rec in slice {
                hot_raw.extend_from_slice(&rec.page.to_le_bytes());
            }
            for rec in slice {
                hot_raw.push(rec.correct);
            }
            for rec in slice {
                let len = rec.msg.len().min(usize::from(u16::MAX)) as u16;
                hot_raw.extend_from_slice(&len.to_le_bytes());
            }
            for rec in slice {
                let len = rec.msg.len().min(usize::from(u16::MAX));
                hot_raw.extend_from_slice(&rec.msg.as_bytes()[..len]);
            }

            let mut cold_raw = Vec::with_capacity(n * 8);
            for col in 0..4 {
                for rec in slice {
                    cold_raw.extend_from_slice(&rec.xywh[col].to_le_bytes());
                }
            }

            let hot_raw_len = hot_raw.len() as u32;
            let cold_raw_len = cold_raw.len() as u32;
            let hot_stored = if self.lz4_hot { lz4_flex::compress(&hot_raw) } else { hot_raw };
            let cold_stored = if self.lz4_cold { lz4_flex::compress(&cold_raw) } else { cold_raw };

            blocks.push(BlockEntryV2 {
                first_article_id: slice.first().unwrap().article_id,
                last_article_id: slice.last().unwrap().article_id,
                first_record: start as u32,
                record_count: n as u32,
                hot_offset: 0,
                hot_len: hot_stored.len() as u32,
                hot_raw_len,
                cold_offset: 0,
                cold_len: cold_stored.len() as u32,
                cold_raw_len,
            });
            hot_payloads.push(hot_stored);
            cold_payloads.push(cold_stored);
        }

        let dir_start = V2_HEADER_LEN
            + (articles.len() as u64) * (V2_ARTICLE_ENTRY_LEN as u64)
            + (blocks.len() as u64) * (V2_BLOCK_ENTRY_LEN as u64);
        let mut cursor = dir_start;
        for b in &mut blocks {
            b.hot_offset = cursor;
            cursor += u64::from(b.hot_len);
        }
        for b in &mut blocks {
            b.cold_offset = cursor;
            cursor += u64::from(b.cold_len);
        }

        let flags = (u32::from(self.lz4_hot) * V2_FLAG_LZ4_HOT)
            | (u32::from(self.lz4_cold) * V2_FLAG_LZ4_COLD);
        writer.write_all(FLAT_V2_MAGIC)?;
        writer.write_all(&FLAT_V2_VERSION.to_le_bytes())?;
        writer.write_all(&flags.to_le_bytes())?;
        writer.write_all(&total_records.to_le_bytes())?;
        writer.write_all(&(blocks.len() as u32).to_le_bytes())?;
        writer.write_all(&(articles.len() as u32).to_le_bytes())?;

        for a in &articles {
            writer.write_all(&a.article_id.to_le_bytes())?;
            writer.write_all(&a.start_record.to_le_bytes())?;
            writer.write_all(&a.record_count.to_le_bytes())?;
        }
        for b in &blocks {
            writer.write_all(&b.first_article_id.to_le_bytes())?;
            writer.write_all(&b.last_article_id.to_le_bytes())?;
            writer.write_all(&b.first_record.to_le_bytes())?;
            writer.write_all(&b.record_count.to_le_bytes())?;
            writer.write_all(&b.hot_offset.to_le_bytes())?;
            writer.write_all(&b.hot_len.to_le_bytes())?;
            writer.write_all(&b.hot_raw_len.to_le_bytes())?;
            writer.write_all(&b.cold_offset.to_le_bytes())?;
            writer.write_all(&b.cold_len.to_le_bytes())?;
            writer.write_all(&b.cold_raw_len.to_le_bytes())?;
        }
        for hot_bytes in &hot_payloads {
            writer.write_all(hot_bytes)?;
        }
        for cold_bytes in &cold_payloads {
            writer.write_all(cold_bytes)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_block_get_handles_corrupt_utf8_and_oob_safely() {
        let block = MessageBlock {
            messages: vec![
                MessageMeta {
                    article_id: 1,
                    page: 0,
                    message: TextRange { offset: 0, len: 2 },
                    correct: 1.0,
                    rects: [0.0; 4],
                },
                MessageMeta {
                    article_id: 2,
                    page: 1,
                    message: TextRange { offset: 1, len: 99 },
                    correct: 0.5,
                    rects: [0.0; 4],
                },
            ],
            message_bytes: vec![0xFF, 0xFE],
        };

        assert!(block.try_get(0).is_none());
        assert!(block.try_get(1).is_none());
        assert_eq!(block.get(0).message, "");
        assert_eq!(block.get(1).message, "");
    }
}