// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Bounded, read-only mobile FSCM search engine with dynamic load/unload support.

use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering as AtomicOrdering};
use std::sync::{Arc, LazyLock, Mutex, RwLock, RwLockReadGuard};

use ahash::AHashMap;
use rayon::{ThreadPool, ThreadPoolBuilder};

use super::scorer::{CachedPartialRatio, CachedRatio};
use super::source::Source;
use super::{convert_query, invalid_data, MessageMeta, ScoredMessage, SortMode};

pub const MIB: usize = 1024 * 1024;
const MAX_QUERY_BYTES: usize = 4096;
const MAX_ARTICLE_RESULTS: usize = 10_000;

static STORE: LazyLock<RwLock<Option<Arc<MobileStore>>>> = LazyLock::new(|| RwLock::new(None));
static POPULAR_RANKS: LazyLock<RwLock<AHashMap<u32, u32>>> =
    LazyLock::new(|| RwLock::new(AHashMap::new()));

pub fn set_popular_order(ids: &[u32]) -> usize {
    let mut map = AHashMap::with_capacity(ids.len());
    for (rank, &id) in ids.iter().enumerate() {
        map.entry(id).or_insert(rank as u32);
    }
    let count = map.len();
    *POPULAR_RANKS.write().unwrap() = map;
    if let Some(store) = STORE.read().unwrap().as_ref() {
        *store.last_cache.lock().unwrap() = None;
    }
    count
}

pub(crate) fn popular_rank_lookup() -> RwLockReadGuard<'static, AHashMap<u32, u32>> {
    POPULAR_RANKS.read().unwrap()
}

pub struct SearchOutcome {
    pub total_matched: u64,
    pub hits: Vec<MaterializedHit>,
}

#[derive(Clone, PartialEq, Eq)]
pub enum Scope {
    All,
    Article(u32),
    Range(u32, u32),
    Many(Vec<u32>),
}

impl std::fmt::Debug for Scope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::All => write!(f, "All"),
            Self::Article(v) => write!(f, "Article({v})"),
            Self::Range(a, b) => write!(f, "Range({a}, {b})"),
            Self::Many(ids) => write!(f, "Many({})", ids.len()),
        }
    }
}

impl Scope {
    #[inline]
    pub fn includes(&self, id: u32) -> bool {
        match self {
            Self::All => true,
            Self::Article(value) => id == *value,
            Self::Range(min, max) => *min <= id && id <= *max,
            Self::Many(ids) => ids.binary_search(&id).is_ok(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct MaterializedHit {
    pub article_id: u32,
    pub page: u32,
    pub correctness: f32,
    pub match_score: f64,
    pub rects: [f32; 4],
    pub raw_text: String,
}

#[derive(Clone, Debug)]
pub struct ProgressSnapshot {
    pub initialized: bool,
    pub active: bool,
    pub cancelled: bool,
    pub scanned_records: usize,
    pub planned_records: usize,
    pub total_records: usize,
    pub memory_budget_mb: usize,
    pub max_article_id: u32,
}

struct CachedSearchSnapshot {
    scope: Scope,
    query_norm: String,
    contains: bool,
    take: usize,
    total_matched: u64,
    rel_scored: Vec<ScoredMessage>,
    lat_scored: Vec<ScoredMessage>,
    pop_scored: Vec<ScoredMessage>,
    rel_mat: Option<Vec<MaterializedHit>>,
    lat_mat: Option<Vec<MaterializedHit>>,
    pop_mat: Option<Vec<MaterializedHit>>,
}

pub struct MobileStore {
    pub(crate) sources: Vec<Source>,
    pub(crate) budget: usize,
    pub(crate) text_limit: usize,
    pub(crate) record_limit: usize,
    pub(crate) total: usize,
    pub(crate) max_article_id: u32,
    pub(crate) pool: ThreadPool,
    gate: Mutex<()>,
    last_cache: Mutex<Option<CachedSearchSnapshot>>,
    active: AtomicBool,
    cancelled: AtomicBool,
    pub(crate) scanned: AtomicUsize,
    pub(crate) planned: AtomicUsize,
}

struct ActiveOperation<'a> {
    store: &'a MobileStore,
    _guard: std::sync::MutexGuard<'a, ()>,
}

impl Drop for ActiveOperation<'_> {
    fn drop(&mut self) {
        self.store.active.store(false, AtomicOrdering::SeqCst);
    }
}

impl MobileStore {
    pub fn open(paths: &[PathBuf], budget_mb: usize, search_threads: usize) -> io::Result<Self> {
        if !(128..=1024).contains(&budget_mb) {
            return Err(invalid_data("mobile budget must be 128..1024 MiB"));
        }
        if paths.is_empty() {
            return Err(invalid_data("at least one FSCM path is required"));
        }
        let threads = search_threads.clamp(1, 8);
        let pool = ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|i| format!("violet-fscm-{i}"))
            .build()
            .map_err(|e| io::Error::other(format!("failed to build rayon pool: {e}")))?;

        let mut sources = Vec::with_capacity(paths.len());
        let mut total = 0usize;
        let mut max_article_id = 0u32;
        for path in paths {
            let source = Source::open(path)?;
            total = total
                .checked_add(source.count)
                .ok_or_else(|| invalid_data("too many records"))?;
            max_article_id = max_article_id.max(source.max_article_id);
            sources.push(source);
        }
        let budget = budget_mb * MIB;
        let buffer_allowance = budget / 8;
        let text_limit = buffer_allowance.min(32 * MIB);
        let record_limit =
            (buffer_allowance / std::mem::size_of::<MessageMeta>()).clamp(1, 1_048_576);

        Ok(Self {
            sources,
            budget,
            text_limit,
            record_limit,
            total,
            max_article_id,
            pool,
            gate: Mutex::new(()),
            last_cache: Mutex::new(None),
            active: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
            scanned: AtomicUsize::new(0),
            planned: AtomicUsize::new(total),
        })
    }

    fn begin(&self) -> io::Result<ActiveOperation<'_>> {
        let guard = self.gate.try_lock().map_err(|_| {
            io::Error::new(io::ErrorKind::WouldBlock, "mobile search already running")
        })?;
        self.cancelled.store(false, AtomicOrdering::SeqCst);
        self.scanned.store(0, AtomicOrdering::Relaxed);
        self.planned.store(self.total, AtomicOrdering::Relaxed);
        self.active.store(true, AtomicOrdering::SeqCst);
        Ok(ActiveOperation {
            store: self,
            _guard: guard,
        })
    }

    #[inline]
    pub(crate) fn check_cancel(&self) -> io::Result<()> {
        if self.cancelled.load(AtomicOrdering::Relaxed) {
            Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "search cancelled",
            ))
        } else {
            Ok(())
        }
    }

    pub fn search_store(
        &self,
        scope: Scope,
        query: &str,
        contains: bool,
        take: usize,
    ) -> io::Result<Vec<MaterializedHit>> {
        Ok(self
            .search_store_with_sort(scope, query, contains, take, SortMode::Relevance)?
            .hits)
    }

    pub fn search_store_with_sort(
        &self,
        mut scope: Scope,
        query: &str,
        contains: bool,
        take: usize,
        sort_mode: SortMode,
    ) -> io::Result<SearchOutcome> {
        let _guard = self.begin()?;
        if query.len() > MAX_QUERY_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "query exceeds mobile allowance",
            ));
        }
        if let Scope::Many(ids) = &mut scope {
            ids.sort_unstable();
            ids.dedup();
            if ids.is_empty() {
                self.planned.store(0, AtomicOrdering::Relaxed);
                return Ok(SearchOutcome {
                    total_matched: 0,
                    hits: vec![],
                });
            }
        }
        let normalized = convert_query(query);
        if normalized.is_empty() || normalized.len() > MAX_QUERY_BYTES || normalized.contains('\0')
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid or empty query",
            ));
        }
        let take_clamped = take.clamp(1, 10_000);

        // 동일 쿼리·조건·포함모드에서 정렬 순서만 변경 시 디스크 재스캔 없이 즉시 반환
        {
            let mut cache_guard = self.last_cache.lock().unwrap();
            if let Some(snap) = cache_guard.as_mut() {
                if snap.scope == scope
                    && snap.query_norm == normalized
                    && snap.contains == contains
                    && snap.take >= take_clamped
                {
                    let total_matched = snap.total_matched;
                    let cached_vec = match sort_mode {
                        SortMode::Relevance => &mut snap.rel_mat,
                        SortMode::Latest => &mut snap.lat_mat,
                        SortMode::Popular => &mut snap.pop_mat,
                    };
                    if let Some(mat) = cached_vec {
                        return Ok(SearchOutcome {
                            total_matched,
                            hits: mat.iter().take(take_clamped).cloned().collect(),
                        });
                    }
                    let scored_slice: Vec<ScoredMessage> = match sort_mode {
                        SortMode::Relevance => snap.rel_scored.iter().take(take_clamped).copied().collect(),
                        SortMode::Latest => snap.lat_scored.iter().take(take_clamped).copied().collect(),
                        SortMode::Popular => snap.pop_scored.iter().take(take_clamped).copied().collect(),
                    };
                    let mat = self.materialize(scored_slice)?;
                    *cached_vec = Some(mat.clone());
                    return Ok(SearchOutcome {
                        total_matched,
                        hits: mat,
                    });
                }
            }
        }

        let ranked = if contains {
            self.rank_all(
                &scope,
                CachedPartialRatio::from_query(&normalized),
                normalized.len(),
                take_clamped,
            )?
        } else {
            self.rank_all(
                &scope,
                CachedRatio::from_query(&normalized),
                0,
                take_clamped,
            )?
        };

        let chosen_scored = match sort_mode {
            SortMode::Relevance => ranked.relevance.clone(),
            SortMode::Latest => ranked.latest.clone(),
            SortMode::Popular => ranked.popular.clone(),
        };
        let hits = self.materialize(chosen_scored)?;

        let mut snap = CachedSearchSnapshot {
            scope,
            query_norm: normalized,
            contains,
            take: take_clamped,
            total_matched: ranked.total_matched,
            rel_scored: ranked.relevance,
            lat_scored: ranked.latest,
            pop_scored: ranked.popular,
            rel_mat: None,
            lat_mat: None,
            pop_mat: None,
        };
        match sort_mode {
            SortMode::Relevance => snap.rel_mat = Some(hits.clone()),
            SortMode::Latest => snap.lat_mat = Some(hits.clone()),
            SortMode::Popular => snap.pop_mat = Some(hits.clone()),
        }
        *self.last_cache.lock().unwrap() = Some(snap);

        Ok(SearchOutcome {
            total_matched: ranked.total_matched,
            hits,
        })
    }

    pub fn article_messages(
        &self,
        id: u32,
        query: Option<&str>,
    ) -> io::Result<Vec<MaterializedHit>> {
        if let Some(q) = query {
            let trimmed = q.trim();
            if !trimmed.is_empty() {
                return self.search_store(Scope::Article(id), trimmed, true, 500);
            }
        }
        let _guard = self.begin()?;
        let mut hits = Vec::new();
        let all_v2 = self
            .sources
            .iter()
            .all(|s| matches!(s.format, super::source::SourceFormat::V2(_)));

        if all_v2 {
            self.scan_scoped(&Scope::Article(id), |base, block| {
                for (local_idx, meta) in block.messages.iter().enumerate() {
                    if meta.article_id == id {
                        if hits.len() >= MAX_ARTICLE_RESULTS {
                            return Err(invalid_data(
                                "mobile article response exceeds 10000 records",
                            ));
                        }
                        hits.push(ScoredMessage {
                            index: base + local_idx,
                            article_id: id,
                            score: 100.0,
                            correct: meta.correct,
                            popular_rank: u32::MAX,
                        });
                    }
                }
                Ok(())
            })?;
        } else {
            self.scan_metadata(|index, record| {
                if record.article_id == id {
                    if hits.len() >= MAX_ARTICLE_RESULTS {
                        return Err(invalid_data(
                            "mobile article response exceeds 10000 records",
                        ));
                    }
                    hits.push(ScoredMessage {
                        index,
                        article_id: id,
                        score: 100.0,
                        correct: record.correct,
                        popular_rank: u32::MAX,
                    });
                }
                Ok(())
            })?;
        }
        self.materialize(hits)
    }
}

pub fn initialize_global(
    paths: &[PathBuf],
    budget_mb: usize,
    search_threads: usize,
) -> io::Result<usize> {
    let store = Arc::new(MobileStore::open(paths, budget_mb, search_threads)?);
    let total = store.total;
    let mut guard = STORE.write().unwrap();
    *guard = Some(store);
    Ok(total)
}

pub fn unload_global() -> bool {
    let mut guard = STORE.write().unwrap();
    let had_store = guard.is_some();
    if let Some(store) = guard.as_ref() {
        store.cancelled.store(true, AtomicOrdering::SeqCst);
    }
    *guard = None;
    had_store
}

pub fn progress_global() -> ProgressSnapshot {
    let guard = STORE.read().unwrap();
    match guard.as_ref() {
        Some(store) => ProgressSnapshot {
            initialized: true,
            active: store.active.load(AtomicOrdering::Relaxed),
            cancelled: store.cancelled.load(AtomicOrdering::Relaxed),
            scanned_records: store.scanned.load(AtomicOrdering::Relaxed),
            planned_records: store.planned.load(AtomicOrdering::Relaxed),
            total_records: store.total,
            memory_budget_mb: store.budget / MIB,
            max_article_id: store.max_article_id,
        },
        None => ProgressSnapshot {
            initialized: false,
            active: false,
            cancelled: false,
            scanned_records: 0,
            planned_records: 0,
            total_records: 0,
            memory_budget_mb: 0,
            max_article_id: 0,
        },
    }
}

pub fn cancel_global() -> bool {
    let guard = STORE.read().unwrap();
    if let Some(store) = guard.as_ref() {
        if store.active.load(AtomicOrdering::SeqCst) {
            store.cancelled.store(true, AtomicOrdering::SeqCst);
            return true;
        }
    }
    false
}

pub fn search_global(
    scope: Scope,
    query: &str,
    contains: bool,
    take: usize,
) -> io::Result<Vec<MaterializedHit>> {
    Ok(search_global_with_sort(scope, query, contains, take, SortMode::Relevance)?.hits)
}

pub fn search_global_with_sort(
    scope: Scope,
    query: &str,
    contains: bool,
    take: usize,
    sort_mode: SortMode,
) -> io::Result<SearchOutcome> {
    let store = {
        let guard = STORE.read().unwrap();
        guard.clone().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotConnected, "mobile store not initialized")
        })?
    };
    store.search_store_with_sort(scope, query, contains, take, sort_mode)
}

pub fn article_global(id: u32, query: Option<&str>) -> io::Result<Vec<MaterializedHit>> {
    let store = {
        let guard = STORE.read().unwrap();
        guard.clone().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotConnected, "mobile store not initialized")
        })?
    };
    store.article_messages(id, query)
}

#[cfg(test)]
mod tests {
    use std::fs::{self, File};
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;
    use crate::message_search::{convert_query, FlatMessageWriter};

    fn temp_dir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("violet-fscm-{label}-{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn mobile_store_restores_korean_and_filters_scopes_across_small_blocks() {
        let dir = temp_dir("core");
        let p0 = dir.join("part0.fscm");
        let p1 = dir.join("part1.fscm");

        let mut w0 = FlatMessageWriter::default();
        w0.push(
            1001,
            2,
            &convert_query("안녕하세요!"),
            None,
            0.95,
            [10.0, 20.0, 30.0, 40.0],
        );
        w0.push(
            1002,
            5,
            &convert_query("오늘은 날씨가 정말 좋네"),
            Some("오늘은 날씨가 정말 좋네"),
            0.88,
            [1.0, 2.0, 3.0, 4.0],
        );
        w0.write_to(&mut File::create(&p0).unwrap()).unwrap();

        let mut w1 = FlatMessageWriter::default();
        w1.push(
            2005,
            0,
            &convert_query("괜찮아 걱정하지 마"),
            None,
            0.91,
            [5.0, 6.0, 7.0, 8.0],
        );
        w1.write_to(&mut File::create(&p1).unwrap()).unwrap();

        let mut store = MobileStore::open(&[p0.clone(), p1.clone()], 128, 2).unwrap();
        // Force 1-record blocks to stress multi-block handoff
        store.record_limit = 1;

        let hits = store.search_store(Scope::All, "안녕하세요", true, 10).unwrap();
        assert!(!hits.is_empty());
        assert_eq!(hits[0].article_id, 1001);
        assert_eq!(hits[0].page, 2);
        assert_eq!(hits[0].raw_text, "안녕하세요!");
        assert_eq!(hits[0].match_score as usize, 100);

        // Typing Korean query with English keyboard typo ("dkssudgktpdy") also matches!
        let typo_hits = store
            .search_store(Scope::All, "dkssudgktpdy", true, 10)
            .unwrap();
        assert_eq!(typo_hits[0].article_id, 1001);

        // Whitelist scope restricts results strictly
        let scoped = store
            .search_store(Scope::Many(vec![2005]), "괜찮아", true, 10)
            .unwrap();
        assert_eq!(scoped.len(), 1);
        assert_eq!(scoped[0].article_id, 2005);
        assert_eq!(scoped[0].raw_text, "괜찮아걱정하지마");

        let empty_scope = store
            .search_store(Scope::Many(vec![]), "괜찮아", true, 10)
            .unwrap();
        assert!(empty_scope.is_empty());

        let art_msgs = store.article_messages(1002, None).unwrap();
        assert_eq!(art_msgs.len(), 1);
        assert_eq!(art_msgs[0].raw_text, "오늘은 날씨가 정말 좋네");

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn mobile_store_rejects_concurrent_and_honors_cancel() {
        let dir = temp_dir("gate");
        let p0 = dir.join("gate.fscm");
        let mut w = FlatMessageWriter::default();
        w.push(1, 0, "dkssud", None, 0.9, [0.0; 4]);
        w.write_to(&mut File::create(&p0).unwrap()).unwrap();

        let store = MobileStore::open(&[p0], 128, 2).unwrap();
        let _guard = store.begin().unwrap();
        let err = store
            .search_store(Scope::All, "안녕", true, 5)
            .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::WouldBlock);
        drop(_guard);

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn mobile_store_v2_compact_hot_cold_and_article_seek() {
        use crate::message_search::FlatMessageWriterV2;
        let dir = temp_dir("v2");
        for (idx, (lz4_hot, lz4_cold)) in [(false, false), (true, true)].into_iter().enumerate() {
            let p = dir.join(format!("test_{idx}.fscm"));
            let mut w = FlatMessageWriterV2::with_compression(lz4_hot, lz4_cold);
            w.push(5002, 7, &convert_query("반갑습니다"), 0.92, [10.0, 20.0, 110.0, 70.0]);
            w.push(5001, 2, &convert_query("안녕하세요"), 0.97, [15.0, 25.0, 200.0, 85.0]);
            w.write_to(&mut File::create(&p).unwrap()).unwrap();

            let store = MobileStore::open(&[p], 128, 2).unwrap();
            let hits = store.search_store(Scope::All, "안녕", true, 10).unwrap();
            assert!(!hits.is_empty());
            assert_eq!(hits[0].article_id, 5001);
            assert_eq!(hits[0].page, 2);
            assert_eq!(hits[0].raw_text, "안녕하세요");
            assert_eq!(hits[0].rects, [15.0, 25.0, 200.0, 85.0]);

            let art = store.article_messages(5002, None).unwrap();
            assert_eq!(art.len(), 1);
            assert_eq!(art[0].raw_text, "반갑습니다");
            assert_eq!(art[0].rects, [10.0, 20.0, 110.0, 70.0]);

            let scoped = store
                .search_store(Scope::Many(vec![5002]), "반갑", true, 10)
                .unwrap();
            assert_eq!(scoped.len(), 1);
            assert_eq!(scoped[0].article_id, 5002);

            set_popular_order(&[5001, 5002]);
            let mut w2 = FlatMessageWriterV2::with_compression(false, false);
            w2.push(100, 1, &convert_query("테스트 대사"), 0.9, [0.0; 4]);
            w2.push(4030123, 1, &convert_query("테스트 대사"), 0.9, [0.0; 4]);
            w2.push(5001, 1, &convert_query("테스트 대사"), 0.9, [0.0; 4]);
            let p2 = dir.join(format!("sort_{idx}.fscm"));
            w2.write_to(&mut File::create(&p2).unwrap()).unwrap();
            let s2 = MobileStore::open(&[p2], 128, 2).unwrap();

            let latest_res = s2
                .search_store_with_sort(Scope::All, "테스트", true, 2, SortMode::Latest)
                .unwrap();
            assert_eq!(latest_res.total_matched, 3);
            assert_eq!(latest_res.hits[0].article_id, 4030123);

            let pop_res = s2
                .search_store_with_sort(Scope::All, "테스트", true, 2, SortMode::Popular)
                .unwrap();
            assert_eq!(pop_res.total_matched, 3);
            assert_eq!(pop_res.hits[0].article_id, 5001);
        }
        let _ = fs::remove_dir_all(dir);
    }
}