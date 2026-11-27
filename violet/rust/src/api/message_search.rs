// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

use std::path::PathBuf;

use crate::message_search::mobile::{
    article_global, cancel_global, initialize_global, progress_global, search_global_with_sort,
    set_popular_order, unload_global, MaterializedHit, Scope,
};
use crate::message_search::source::Source;
use crate::message_search::SortMode;

#[derive(Clone, Debug)]
pub struct MobileSearchFilter {
    pub article_id: Option<u32>,
    pub id_min: Option<u32>,
    pub id_max: Option<u32>,
    pub whitelist_ids: Option<Vec<u32>>,
    pub sort_mode: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct MobileSearchResponse {
    pub total_matched: u64,
    pub hits: Vec<MobileMessageHit>,
}

#[derive(Clone, Debug)]
pub struct MobileMessageHit {
    pub article_id: u32,
    pub page: u32,
    pub match_score: f64,
    pub correctness: f32,
    pub rect: Vec<f32>,
    pub raw_text: String,
}

#[derive(Clone, Debug)]
pub struct MobileSearchProgress {
    pub initialized: bool,
    pub active: bool,
    pub cancelled: bool,
    pub scanned_records: u64,
    pub planned_records: u64,
    pub total_records: u64,
    pub memory_budget_mb: u32,
    pub max_article_id: u32,
}

#[derive(Clone, Debug)]
pub struct FscmFileInfo {
    pub path: String,
    pub record_count: u64,
    pub text_bytes: u64,
    pub has_raw_flag: bool,
    pub max_article_id: u32,
}

impl From<MaterializedHit> for MobileMessageHit {
    fn from(v: MaterializedHit) -> Self {
        Self {
            article_id: v.article_id,
            page: v.page,
            match_score: v.match_score,
            correctness: v.correctness,
            rect: v.rects.to_vec(),
            raw_text: v.raw_text,
        }
    }
}

/// 기기 총 물리 메모리(MiB)를 조회합니다. 조회 실패 시 0을 반환합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn device_total_ram_mb() -> u64 {
    query_total_ram_mb()
}

/// 기기 RAM 용량에 맞춰 최적의 모바일 대사 검색 메모리 예산(128 / 256 / 512 MiB)을 자동 선택합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn recommended_mobile_budget_mb() -> u32 {
    let ram = query_total_ram_mb();
    if ram == 0 {
        return 256;
    }
    if ram <= 3584 {
        128
    } else if ram <= 6656 {
        256
    } else {
        512
    }
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn query_total_ram_mb() -> u64 {
    let Ok(content) = std::fs::read_to_string("/proc/meminfo") else {
        return 0;
    };
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            let kb: u64 = rest
                .split_whitespace()
                .next()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            return kb / 1024;
        }
    }
    0
}

#[cfg(target_os = "windows")]
fn query_total_ram_mb() -> u64 {
    #[repr(C)]
    struct MemoryStatusEx {
        dw_length: u32,
        dw_memory_load: u32,
        ull_total_phys: u64,
        ull_avail_phys: u64,
        ull_total_page_file: u64,
        ull_avail_page_file: u64,
        ull_total_virtual: u64,
        ull_avail_virtual: u64,
        ull_avail_extended_virtual: u64,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GlobalMemoryStatusEx(lp_buffer: *mut MemoryStatusEx) -> i32;
    }
    let mut mem = MemoryStatusEx {
        dw_length: std::mem::size_of::<MemoryStatusEx>() as u32,
        dw_memory_load: 0,
        ull_total_phys: 0,
        ull_avail_phys: 0,
        ull_total_page_file: 0,
        ull_avail_page_file: 0,
        ull_total_virtual: 0,
        ull_avail_virtual: 0,
        ull_avail_extended_virtual: 0,
    };
    let ok = unsafe { GlobalMemoryStatusEx(&mut mem) };
    if ok != 0 {
        mem.ull_total_phys / (1024 * 1024)
    } else {
        0
    }
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
fn query_total_ram_mb() -> u64 {
    let mut memsize: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    let name = c"hw.memsize";
    let ret = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut memsize as *mut u64).cast::<libc::c_void>(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if ret == 0 {
        memsize / (1024 * 1024)
    } else {
        0
    }
}

#[cfg(not(any(
    target_os = "android",
    target_os = "linux",
    target_os = "windows",
    target_os = "ios",
    target_os = "macos"
)))]
fn query_total_ram_mb() -> u64 {
    0
}

/// `.fscm` 파일의 매직 헤더(FSCMMSG1/FSCMMSG2), 버전, 파일 길이 정합성을 O(1)로 검증합니다.
pub fn verify_fscm_file(path: String) -> Result<FscmFileInfo, String> {
    let pb = PathBuf::from(&path);
    let src = Source::open(&pb).map_err(|e| format!("Invalid FSCM file '{path}': {e}"))?;
    Ok(FscmFileInfo {
        path,
        record_count: src.count as u64,
        text_bytes: src.bytes,
        has_raw_flag: src.has_raw_flag,
        max_article_id: src.max_article_id,
    })
}

/// 한국어 `.fscm` 파일들로 모바일 경량 대사 검색 엔진을 초기화합니다.
pub fn mobile_search_init(
    paths: Vec<String>,
    budget_mb: u32,
    search_threads: u32,
) -> Result<u64, String> {
    let path_bufs: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
    let total = initialize_global(&path_bufs, budget_mb as usize, search_threads as usize)
        .map_err(|e| format!("Failed to initialize mobile search: {e}"))?;
    Ok(total as u64)
}

/// 설정 토글 OFF 또는 레코드 삭제 시 엔진을 언로드합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn mobile_search_unload() -> bool {
    unload_global()
}

/// 실시간 스캔 진행률을 코퍼스 접근 없이 즉시 반환합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn mobile_search_progress() -> MobileSearchProgress {
    let p = progress_global();
    MobileSearchProgress {
        initialized: p.initialized,
        active: p.active,
        cancelled: p.cancelled,
        scanned_records: p.scanned_records as u64,
        planned_records: p.planned_records as u64,
        total_records: p.total_records as u64,
        memory_budget_mb: p.memory_budget_mb as u32,
        max_article_id: p.max_article_id,
    }
}

/// 현재 진행 중인 모바일 대사 검색에 즉시 취소 신호를 보냅니다.
#[flutter_rust_bridge::frb(sync)]
pub fn mobile_search_cancel() -> bool {
    cancel_global()
}

/// 인기순 정렬을 위한 작품 ID 순위 목록(`assets/rank/population.json` 순서)을 Rust 엔진에 등록합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn mobile_search_set_popular_ids(ids: Vec<u32>) -> u32 {
    set_popular_order(&ids) as u32
}

/// 전체·범위·작품 조건 화이트리스트 대상 모바일 경량 대사 검색을 실행합니다.
pub fn mobile_search_query(
    query: String,
    contains_mode: bool,
    take: u32,
    filter: Option<MobileSearchFilter>,
) -> Result<Vec<MobileMessageHit>, String> {
    let res = mobile_search_query_ex(query, contains_mode, take, filter)?;
    Ok(res.hits)
}

/// 전체 일치 건수(`total_matched`) 및 정렬 옵션(`sort_mode`)을 포함한 대사 검색을 실행합니다.
pub fn mobile_search_query_ex(
    query: String,
    contains_mode: bool,
    take: u32,
    filter: Option<MobileSearchFilter>,
) -> Result<MobileSearchResponse, String> {
    let sort_mode = SortMode::from_u32(filter.as_ref().and_then(|f| f.sort_mode).unwrap_or(0));
    let internal_scope = match filter {
        None => Scope::All,
        Some(f) => {
            if let Some(aid) = f.article_id {
                Scope::Article(aid)
            } else if let Some(mut ids) = f.whitelist_ids {
                if let Some(min_v) = f.id_min {
                    ids.retain(|&id| id >= min_v);
                }
                if let Some(max_v) = f.id_max {
                    ids.retain(|&id| id <= max_v);
                }
                Scope::Many(ids)
            } else if f.id_min.is_some() || f.id_max.is_some() {
                let min_v = f.id_min.unwrap_or(0);
                let max_v = f.id_max.unwrap_or(u32::MAX);
                if min_v > max_v {
                    return Err("id_min must be <= id_max".to_string());
                }
                Scope::Range(min_v, max_v)
            } else {
                Scope::All
            }
        }
    };

    let outcome =
        search_global_with_sort(internal_scope, &query, contains_mode, take as usize, sort_mode)
            .map_err(|e| e.to_string())?;
    Ok(MobileSearchResponse {
        total_matched: outcome.total_matched,
        hits: outcome.hits.into_iter().map(MobileMessageHit::from).collect(),
    })
}

/// 뷰어 내 단일 작품 대사 검색(또는 빈 쿼리 시 작품 전체 대사 조회)을 수행합니다.
pub fn mobile_search_article(
    article_id: u32,
    query: String,
) -> Result<Vec<MobileMessageHit>, String> {
    let q_opt = (!query.trim().is_empty()).then_some(query.as_str());
    let hits = article_global(article_id, q_opt).map_err(|e| e.to_string())?;
    Ok(hits.into_iter().map(MobileMessageHit::from).collect())
}

#[derive(Clone, Debug)]
pub struct FscmBuildEntry {
    pub article_id: u32,
    pub page: u32,
    pub text: String,
    pub store_raw: bool,
    pub correctness: f32,
    pub rect: Vec<f32>,
}

/// 한국어 대사 엔트리 목록을 받아 `.fscm` 바이너리 파일을 생성합니다 (테스트 픽스처 및 로컬 패키징 공용).
pub fn build_fscm_file(output_path: String, mut entries: Vec<FscmBuildEntry>) -> Result<u64, String> {
    entries.sort_by(|a, b| a.article_id.cmp(&b.article_id).then(a.page.cmp(&b.page)));
    let mut writer = crate::message_search::FlatMessageWriter::default();
    let mut written = 0u64;
    for entry in entries {
        let encoded = crate::message_search::convert_query(&entry.text);
        if encoded.is_empty() {
            continue;
        }
        let mut rects = [0.0f32; 4];
        for (i, v) in entry.rect.iter().take(4).enumerate() {
            rects[i] = *v;
        }
        let raw_opt = entry.store_raw.then_some(entry.text.as_str());
        writer.push(
            entry.article_id,
            entry.page,
            &encoded,
            raw_opt,
            entry.correctness,
            rects,
        );
        written += 1;
    }
    let file = std::fs::File::create(&output_path)
        .map_err(|e| format!("Failed to create FSCM '{output_path}': {e}"))?;
    let mut buf = std::io::BufWriter::new(file);
    writer
        .write_to(&mut buf)
        .map_err(|e| format!("Failed to write FSCM '{output_path}': {e}"))?;
    Ok(written)
}