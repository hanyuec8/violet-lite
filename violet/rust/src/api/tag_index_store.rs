// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Native in-memory tag/relation index store matching `message_search::mobile`'s store pattern.
//! Keeps heavy JSON relation maps out of the Dart heap and accelerates fuzzy/cosine search.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, RwLock, RwLockReadGuard, RwLockWriteGuard};

use rapidfuzz::distance::levenshtein;
use rayon::prelude::*;
use serde::Deserialize;

type CountMap = HashMap<String, i64>;
type NestedScoreMap = HashMap<String, HashMap<String, f64>>;

#[derive(Debug, Clone)]
pub struct TagIndexSummary {
    pub loaded: bool,
    pub tag_count_groups: u32,
    pub artist_entries: u32,
    pub group_entries: u32,
    pub series_entries: u32,
    pub character_entries: u32,
}

#[derive(Debug, Clone)]
pub struct TagCountItem {
    pub group: String,
    pub name: String,
    pub count: i64,
}

#[derive(Debug, Clone)]
pub struct TagFuzzyItem {
    pub group: String,
    pub name: String,
    pub distance: u32,
    pub count: i64,
}

#[derive(Debug, Clone)]
pub struct TagScoreItem {
    pub key: String,
    pub score: f64,
}

#[flutter_rust_bridge::frb(ignore)]
struct TagIndexStore {
    tag_count: HashMap<String, CountMap>,
    tag_artist: NestedScoreMap,
    tag_group: NestedScoreMap,
    tag_uploader: NestedScoreMap,
    tag_series: NestedScoreMap,
    tag_character: NestedScoreMap,
    character_series: NestedScoreMap,
    series_character: NestedScoreMap,
    character_character: NestedScoreMap,
    series_series: NestedScoreMap,
}

impl TagIndexStore {
    fn empty() -> Self {
        Self {
            tag_count: HashMap::new(),
            tag_artist: HashMap::new(),
            tag_group: HashMap::new(),
            tag_uploader: HashMap::new(),
            tag_series: HashMap::new(),
            tag_character: HashMap::new(),
            character_series: HashMap::new(),
            series_character: HashMap::new(),
            character_character: HashMap::new(),
            series_series: HashMap::new(),
        }
    }
}

static TAG_STORE: LazyLock<RwLock<Option<TagIndexStore>>> = LazyLock::new(|| RwLock::new(None));

#[inline]
fn read_lock<T>(lock: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(|e| e.into_inner())
}

#[inline]
fn write_lock<T>(lock: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    lock.write().unwrap_or_else(|e| e.into_inner())
}

fn resolve_index_file(base_dir: &Path, is_android: bool, filename: &str) -> PathBuf {
    if is_android {
        let sub = base_dir.join("data").join(filename);
        if sub.exists() {
            return sub;
        }
    }
    let direct = base_dir.join(filename);
    if direct.exists() {
        return direct;
    }
    if is_android {
        base_dir.join("data").join(filename)
    } else {
        direct
    }
}

fn load_optional_json<T: for<'de> Deserialize<'de> + Default>(path: &Path) -> Result<T, String> {
    match fs::read_to_string(path) {
        Ok(s) => serde_json::from_str::<T>(&s)
            .map_err(|e| format!("failed to parse '{}': {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(e) => Err(format!("failed to read '{}': {e}", path.display())),
    }
}

fn split_gender_tags(tag_count: &mut HashMap<String, CountMap>) {
    let Some(tags_map) = tag_count.get_mut("tag") else {
        return;
    };
    let mut females = CountMap::new();
    let mut males = CountMap::new();
    let mut to_remove = Vec::new();

    for (k, &v) in tags_map.iter() {
        if let Some(rest) = k.strip_prefix("female:") {
            females.insert(rest.to_string(), v);
            to_remove.push(k.clone());
        } else if let Some(rest) = k.strip_prefix("male:") {
            males.insert(rest.to_string(), v);
            to_remove.push(k.clone());
        }
    }
    for k in to_remove {
        tags_map.remove(&k);
    }
    if !females.is_empty() {
        tag_count.insert("female".to_string(), females);
    }
    if !males.is_empty() {
        tag_count.insert("male".to_string(), males);
    }
}

#[flutter_rust_bridge::frb(ignore)]
fn load_store_from_disk(base_dir: &str, is_android: bool) -> Result<TagIndexStore, String> {
    let base = Path::new(base_dir);
    let mut store = TagIndexStore::empty();

    let index_path = resolve_index_file(base, is_android, "index.json");
    if index_path.exists() {
        store.tag_count = load_optional_json(&index_path)?;
        split_gender_tags(&mut store.tag_count);
    }

    let tag_artist_path = resolve_index_file(base, is_android, "tag-artist.json");
    if tag_artist_path.exists() {
        store.tag_artist = load_optional_json(&tag_artist_path)?;
        store.tag_group =
            load_optional_json(&resolve_index_file(base, is_android, "tag-group.json"))?;
        store.tag_uploader =
            load_optional_json(&resolve_index_file(base, is_android, "tag-uploader.json"))?;
        store.tag_series =
            load_optional_json(&resolve_index_file(base, is_android, "tag-series.json"))?;
        store.tag_character =
            load_optional_json(&resolve_index_file(base, is_android, "tag-character.json"))?;
        store.character_series =
            load_optional_json(&resolve_index_file(base, is_android, "character-series.json"))?;
        store.series_character =
            load_optional_json(&resolve_index_file(base, is_android, "series-character.json"))?;
        store.character_character =
            load_optional_json(&resolve_index_file(base, is_android, "character-character.json"))?;
        store.series_series =
            load_optional_json(&resolve_index_file(base, is_android, "series-series.json"))?;
    }

    Ok(store)
}

/// 디스크의 태그 카운트 및 10종 관계 인덱스 JSON을 Rust 인메모리 스토어로 비동기 적재합니다.
pub fn tag_index_load(base_dir: String, is_android: bool) -> Result<TagIndexSummary, String> {
    let store = load_store_from_disk(&base_dir, is_android)?;
    let summary = TagIndexSummary {
        loaded: !store.tag_count.is_empty() || !store.tag_artist.is_empty(),
        tag_count_groups: store.tag_count.len() as u32,
        artist_entries: store.tag_artist.len() as u32,
        group_entries: store.tag_group.len() as u32,
        series_entries: store.tag_series.len() as u32,
        character_entries: store.tag_character.len() as u32,
    };
    *write_lock(&TAG_STORE) = Some(store);
    Ok(summary)
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_is_loaded() -> bool {
    read_lock(&TAG_STORE).is_some()
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_get_count(classification: String, name: String) -> i64 {
    let guard = read_lock(&TAG_STORE);
    let Some(store) = guard.as_ref() else {
        return 0;
    };
    let Some(map) = store.tag_count.get(&classification) else {
        return 0;
    };
    let clean = name.trim();
    let lower = clean.to_lowercase();
    let space = lower.replace('_', " ");
    let under = lower.replace(' ', "_");
    map.get(clean)
        .or_else(|| map.get(&lower))
        .or_else(|| map.get(&space))
        .or_else(|| map.get(&under))
        .copied()
        .unwrap_or(0)
        .max(0)
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_get_group_counts(group: String) -> Vec<TagCountItem> {
    let guard = read_lock(&TAG_STORE);
    let Some(store) = guard.as_ref() else {
        return Vec::new();
    };
    let Some(map) = store.tag_count.get(&group) else {
        return Vec::new();
    };
    map.iter()
        .map(|(k, &v)| TagCountItem {
            group: group.clone(),
            name: k.clone(),
            count: v,
        })
        .collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_search_contains(group: Option<String>, query: String) -> Vec<TagCountItem> {
    let guard = read_lock(&TAG_STORE);
    let Some(store) = guard.as_ref() else {
        return Vec::new();
    };
    let q_lower = query.to_lowercase();
    let mut out = Vec::new();

    if let Some(grp) = group {
        if let Some(map) = store.tag_count.get(&grp) {
            for (k, &v) in map {
                if k.to_lowercase().contains(&q_lower) {
                    out.push(TagCountItem {
                        group: grp.clone(),
                        name: k.clone(),
                        count: v,
                    });
                }
            }
        }
    } else {
        for (grp, map) in &store.tag_count {
            for (k, &v) in map {
                if k.to_lowercase().contains(&q_lower) {
                    out.push(TagCountItem {
                        group: grp.clone(),
                        name: k.clone(),
                        count: v,
                    });
                }
            }
        }
    }
    out
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_search_fuzzy(
    group: Option<String>,
    query: String,
    limit: u32,
) -> Vec<TagFuzzyItem> {
    let guard = read_lock(&TAG_STORE);
    let Some(store) = guard.as_ref() else {
        return Vec::new();
    };

    let q_chars: Vec<u32> = query.to_lowercase().replace('_', " ").chars().map(|c| c as u32).collect();
    let cmp = levenshtein::BatchComparator::new(q_chars.iter().copied());

    let mut entries: Vec<(&str, &str, i64)> = Vec::new();
    if let Some(ref grp) = group {
        if let Some(map) = store.tag_count.get(grp.as_str()) {
            for (k, &v) in map {
                entries.push((grp.as_str(), k.as_str(), v));
            }
        }
    } else {
        for (grp, map) in &store.tag_count {
            for (k, &v) in map {
                entries.push((grp.as_str(), k.as_str(), v));
            }
        }
    }

    let mut scored: Vec<TagFuzzyItem> = entries
        .par_iter()
        .map(|&(grp, name, count)| {
            let dist = cmp.distance(name.chars().map(|c| c as u32)) as u32;
            TagFuzzyItem {
                group: grp.to_string(),
                name: name.to_string(),
                distance: dist,
                count,
            }
        })
        .collect();

    scored.sort_unstable_by(|a, b| a.distance.cmp(&b.distance).then(b.count.cmp(&a.count)));
    if limit > 0 && scored.len() > limit as usize {
        scored.truncate(limit as usize);
    }
    scored
}

fn cosine_distance_pct(l1: &HashMap<String, f64>, l2: &HashMap<String, f64>) -> f64 {
    let mut xx = 0.0f64;
    let mut yy = 0.0f64;
    for &v in l1.values() {
        xx += v * v;
    }
    for &v in l2.values() {
        yy += v * v;
    }
    if xx == 0.0 || yy == 0.0 {
        return 0.0;
    }
    let (small, large) = if l1.len() <= l2.len() {
        (l1, l2)
    } else {
        (l2, l1)
    };
    let mut dot = 0.0f64;
    for (k, &v1) in small {
        if let Some(&v2) = large.get(k) {
            dot += v1 * v2;
        }
    }
    dot / (xx.sqrt() * yy.sqrt()) * 100.0
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_calculate_similars(kind: String, key: String) -> Vec<TagScoreItem> {
    let guard = read_lock(&TAG_STORE);
    let Some(store) = guard.as_ref() else {
        return Vec::new();
    };
    let map = match kind.as_str() {
        "artist" => &store.tag_artist,
        "group" => &store.tag_group,
        "uploader" => &store.tag_uploader,
        "series" => &store.tag_series,
        "character" => &store.tag_character,
        "character_series" => &store.character_series,
        "series_character" => &store.series_character,
        _ => return Vec::new(),
    };
    let Some(target) = map.get(&key) else {
        return Vec::new();
    };
    let mut results: Vec<TagScoreItem> = map
        .par_iter()
        .filter_map(|(other_key, other_vec)| {
            if other_key == &key || other_key.eq_ignore_ascii_case("n/a") {
                return None;
            }
            let dist = cosine_distance_pct(target, other_vec);
            (dist > 0.00001).then(|| TagScoreItem {
                key: other_key.clone(),
                score: dist,
            })
        })
        .collect();

    results.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));
    results
}

#[flutter_rust_bridge::frb(sync)]
pub fn tag_index_get_related_pairs(kind: String, key: String) -> Vec<TagScoreItem> {
    let guard = read_lock(&TAG_STORE);
    let Some(store) = guard.as_ref() else {
        return Vec::new();
    };
    let map = match kind.as_str() {
        "series_series" => &store.series_series,
        "character_character" => &store.character_character,
        "character_series" => &store.character_series,
        "series_character" => &store.series_character,
        _ => return Vec::new(),
    };
    let Some(inner) = map.get(&key) else {
        return Vec::new();
    };
    let mut out: Vec<TagScoreItem> = inner
        .iter()
        .map(|(k, &v)| TagScoreItem {
            key: k.clone(),
            score: v,
        })
        .collect();
    out.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn loads_test_db_and_computes_fuzzy_and_cosine_similars() {
        let db_dir = Path::new("../test/db");
        if !db_dir.join("index.json").exists() {
            return;
        }
        let summary = tag_index_load(db_dir.to_string_lossy().to_string(), false).unwrap();
        assert!(summary.loaded);
        assert!(tag_index_is_loaded());

        let fuzzy = tag_index_search_fuzzy(Some("artist".to_string()), "michoking".to_string(), 5);
        assert!(!fuzzy.is_empty());
        assert_eq!(fuzzy[0].name, "michiking");
    }

    #[test]
    fn synthetic_cosine_and_count_lookup() {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("violet-tag-store-{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("index.json"),
            r#"{"tag":{"female:elf":12,"full color":5},"artist":{"kuuchuu yousai":45}}"#,
        )
        .unwrap();
        fs::write(
            dir.join("tag-artist.json"),
            r#"{"a":{"1":10,"2":5},"b":{"1":8,"2":4},"c":{"3":9}}"#,
        )
        .unwrap();

        let summary = tag_index_load(dir.to_string_lossy().to_string(), false).unwrap();
        assert!(summary.loaded);
        assert_eq!(tag_index_get_count("artist".to_string(), "kuuchuu_yousai".to_string()), 45);
        assert_eq!(tag_index_get_count("female".to_string(), "elf".to_string()), 12);

        let sims = tag_index_calculate_similars("artist".to_string(), "a".to_string());
        assert_eq!(sims.len(), 1);
        assert_eq!(sims[0].key, "b");
        assert!((sims[0].score - 100.0).abs() < 1e-6);

        let _ = fs::remove_dir_all(dir);
    }
}
