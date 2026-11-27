// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Ultra-fast incremental delta updater for Violet's 11 local tag/relation JSON indexes.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::{Deserialize, Serialize};

#[flutter_rust_bridge::frb(ignore)]
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct ArticleIndexRow {
    #[serde(rename = "Id", alias = "id", default)]
    pub id: i64,
    #[serde(rename = "Tags", alias = "tags")]
    pub tags: Option<String>,
    #[serde(rename = "Artists", alias = "artists")]
    pub artists: Option<String>,
    #[serde(rename = "Groups", alias = "groups")]
    pub groups: Option<String>,
    #[serde(rename = "Series", alias = "series")]
    pub series: Option<String>,
    #[serde(rename = "Characters", alias = "characters")]
    pub characters: Option<String>,
    #[serde(rename = "Language", alias = "language")]
    pub language: Option<String>,
    #[serde(rename = "Type", alias = "article_type")]
    pub article_type: Option<String>,
    #[serde(rename = "Uploader", alias = "uploader")]
    pub uploader: Option<String>,
    #[serde(rename = "Class", alias = "class_name")]
    pub class_name: Option<String>,
}

#[derive(Clone, Debug)]
pub struct IndexSyncStats {
    pub added_or_updated: u32,
    pub removed: u32,
    pub total_unique_tags: u32,
    pub elapsed_ms: u64,
}

type CountMap = HashMap<String, i64>;
type NestedCountMap = HashMap<String, CountMap>;

#[flutter_rust_bridge::frb(ignore)]
#[derive(Default, Deserialize, Serialize)]
struct MainIndexJson {
    #[serde(default)]
    tag: CountMap,
    #[serde(default)]
    artist: CountMap,
    #[serde(default)]
    group: CountMap,
    #[serde(default)]
    series: CountMap,
    #[serde(default)]
    lang: CountMap,
    #[serde(rename = "type", default)]
    article_type: CountMap,
    #[serde(default)]
    uploader: CountMap,
    #[serde(default)]
    character: CountMap,
    #[serde(rename = "class", default)]
    class_name: CountMap,
}

#[inline]
fn split_pipe(raw: &Option<String>) -> impl Iterator<Item = &str> {
    raw.as_deref()
        .unwrap_or("")
        .split('|')
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

#[inline]
fn add_delta(map: &mut CountMap, key: &str, delta: i64) {
    if key.is_empty() || delta == 0 {
        return;
    }
    let entry = map.entry(key.to_string()).or_insert(0);
    *entry += delta;
    if *entry <= 0 {
        map.remove(key);
    }
}

fn load_json_or_missing<T: for<'de> Deserialize<'de> + Default>(path: &Path) -> Result<T, String> {
    match fs::read_to_string(path) {
        Ok(s) => serde_json::from_str::<T>(&s)
            .map_err(|e| format!("corrupted json '{}': {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(e) => Err(format!("failed to read '{}': {e}", path.display())),
    }
}

fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            fs::create_dir_all(parent).map_err(|e| format!("mkdir failed: {e}"))?;
        }
    }
    let tmp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(value).map_err(|e| format!("serialize failed: {e}"))?;
    {
        use std::io::Write;
        let mut f = fs::File::create(&tmp).map_err(|e| format!("create tmp failed: {e}"))?;
        f.write_all(&bytes)
            .map_err(|e| format!("write tmp failed: {e}"))?;
        f.sync_all().map_err(|e| format!("sync tmp failed: {e}"))?;
    }
    fs::rename(&tmp, path).map_err(|e| format!("atomic rename failed: {e}"))
}

fn update_rel_tag(
    targets: &Option<String>,
    tags: &Option<String>,
    tag_index: &mut HashMap<String, usize>,
    next_tag_idx: &mut usize,
    rel_map: &mut NestedCountMap,
    delta: i64,
) {
    let target_list: Vec<&str> = split_pipe(targets).collect();
    if target_list.is_empty() {
        return;
    }
    for tag in split_pipe(tags) {
        let idx = match tag_index.get(tag) {
            Some(&id) => id,
            None => {
                if delta <= 0 {
                    continue;
                }
                let id = *next_tag_idx;
                *next_tag_idx += 1;
                tag_index.insert(tag.to_string(), id);
                id
            }
        };
        let idx_str = idx.to_string();
        for &target in &target_list {
            let inner = rel_map.entry(target.to_string()).or_default();
            add_delta(inner, &idx_str, delta);
            if inner.is_empty() {
                rel_map.remove(target);
            }
        }
    }
}

fn update_rel_pair(
    sources: &Option<String>,
    targets: &Option<String>,
    rel_map: &mut NestedCountMap,
    delta: i64,
) {
    let target_list: Vec<&str> = split_pipe(targets).collect();
    if target_list.is_empty() {
        return;
    }
    for src in split_pipe(sources) {
        let inner = rel_map.entry(src.to_string()).or_default();
        for &tgt in &target_list {
            add_delta(inner, tgt, delta);
        }
        if inner.is_empty() {
            rel_map.remove(src);
        }
    }
}

fn apply_row_to_main_index(row: &ArticleIndexRow, delta: i64, main_idx: &mut MainIndexJson) {
    for t in split_pipe(&row.tags) {
        add_delta(&mut main_idx.tag, t, delta);
    }
    for a in split_pipe(&row.artists) {
        add_delta(&mut main_idx.artist, a, delta);
    }
    for g in split_pipe(&row.groups) {
        add_delta(&mut main_idx.group, g, delta);
    }
    for s in split_pipe(&row.series) {
        add_delta(&mut main_idx.series, s, delta);
    }
    for c in split_pipe(&row.characters) {
        add_delta(&mut main_idx.character, c, delta);
    }
    if let Some(lang) = row.language.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        add_delta(&mut main_idx.lang, lang, delta);
    }
    if let Some(tp) = row.article_type.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        add_delta(&mut main_idx.article_type, tp, delta);
    }
    if let Some(up) = row.uploader.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        add_delta(&mut main_idx.uploader, up, delta);
    }
    if let Some(cl) = row.class_name.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        add_delta(&mut main_idx.class_name, cl, delta);
    }
}

fn process_rel_tag_file<F>(
    path: &Path,
    removed: &[ArticleIndexRow],
    added: &[ArticleIndexRow],
    tag_index: &mut HashMap<String, usize>,
    next_tag_idx: &mut usize,
    extract: F,
) -> Result<(), String>
where
    F: Fn(&ArticleIndexRow) -> &Option<String>,
{
    let mut rel_map: NestedCountMap = load_json_or_missing(path)?;
    for r in removed {
        if r.tags.as_deref().is_some_and(|s| !s.is_empty()) {
            update_rel_tag(extract(r), &r.tags, tag_index, next_tag_idx, &mut rel_map, -1);
        }
    }
    for r in added {
        if r.tags.as_deref().is_some_and(|s| !s.is_empty()) {
            update_rel_tag(extract(r), &r.tags, tag_index, next_tag_idx, &mut rel_map, 1);
        }
    }
    write_json_atomic(path, &rel_map)
}

fn process_rel_pair_file<F1, F2>(
    path: &Path,
    removed: &[ArticleIndexRow],
    added: &[ArticleIndexRow],
    extract_src: F1,
    extract_tgt: F2,
) -> Result<(), String>
where
    F1: Fn(&ArticleIndexRow) -> &Option<String>,
    F2: Fn(&ArticleIndexRow) -> &Option<String>,
{
    let mut rel_map: NestedCountMap = load_json_or_missing(path)?;
    for r in removed {
        update_rel_pair(extract_src(r), extract_tgt(r), &mut rel_map, -1);
    }
    for r in added {
        update_rel_pair(extract_src(r), extract_tgt(r), &mut rel_map, 1);
    }
    write_json_atomic(path, &rel_map)
}

pub(crate) fn apply_index_delta_sync(
    data_dir: &str,
    removed_rows_json: &str,
    added_rows_json: &str,
) -> Result<IndexSyncStats, String> {
    let started = Instant::now();
    let removed: Vec<ArticleIndexRow> = if removed_rows_json.trim().is_empty() {
        Vec::new()
    } else {
        serde_json::from_str(removed_rows_json)
            .map_err(|e| format!("invalid removed_rows_json: {e}"))?
    };
    let added: Vec<ArticleIndexRow> = if added_rows_json.trim().is_empty() {
        Vec::new()
    } else {
        serde_json::from_str(added_rows_json)
            .map_err(|e| format!("invalid added_rows_json: {e}"))?
    };

    let base = PathBuf::from(data_dir);
    if !base.exists() {
        fs::create_dir_all(&base).map_err(|e| format!("failed to create {data_dir}: {e}"))?;
    }

    if removed.is_empty() && added.is_empty() {
        return Ok(IndexSyncStats {
            added_or_updated: 0,
            removed: 0,
            total_unique_tags: 0,
            elapsed_ms: 0,
        });
    }

    // 1. index.json 단독 로드 -> 병합 -> 원자적 저장 -> 해제
    let p_index = base.join("index.json");
    let total_unique_tags = {
        let mut main_idx: MainIndexJson = load_json_or_missing(&p_index)?;
        for r in &removed {
            apply_row_to_main_index(r, -1, &mut main_idx);
        }
        for r in &added {
            apply_row_to_main_index(r, 1, &mut main_idx);
        }
        for std_lang in [
            "korean", "japanese", "english", "chinese", "spanish", "french", "german", "russian",
        ] {
            main_idx.lang.entry(std_lang.to_string()).or_insert(0);
        }
        let unique = main_idx.tag.len() as u32;
        write_json_atomic(&p_index, &main_idx)?;
        unique
    };

    // 2. tag-index.json + 5종 태그 관계 맵을 1개씩 순차 로드 -> 병합 -> 저장 -> 해제
    let p_tag_index = base.join("tag-index.json");
    let mut tag_index: HashMap<String, usize> = load_json_or_missing(&p_tag_index)?;
    let mut next_tag_idx = tag_index.values().copied().max().map_or(0, |m| m + 1);

    process_rel_tag_file(
        &base.join("tag-artist.json"),
        &removed,
        &added,
        &mut tag_index,
        &mut next_tag_idx,
        |r| &r.artists,
    )?;
    process_rel_tag_file(
        &base.join("tag-group.json"),
        &removed,
        &added,
        &mut tag_index,
        &mut next_tag_idx,
        |r| &r.groups,
    )?;
    process_rel_tag_file(
        &base.join("tag-uploader.json"),
        &removed,
        &added,
        &mut tag_index,
        &mut next_tag_idx,
        |r| &r.uploader,
    )?;
    process_rel_tag_file(
        &base.join("tag-series.json"),
        &removed,
        &added,
        &mut tag_index,
        &mut next_tag_idx,
        |r| &r.series,
    )?;
    process_rel_tag_file(
        &base.join("tag-character.json"),
        &removed,
        &added,
        &mut tag_index,
        &mut next_tag_idx,
        |r| &r.characters,
    )?;
    write_json_atomic(&p_tag_index, &tag_index)?;
    drop(tag_index);

    // 3. 4종 상호 관계 맵을 1개씩 순차 로드 -> 병합 -> 저장 -> 해제
    process_rel_pair_file(
        &base.join("character-series.json"),
        &removed,
        &added,
        |r| &r.series,
        |r| &r.characters,
    )?;
    process_rel_pair_file(
        &base.join("series-character.json"),
        &removed,
        &added,
        |r| &r.characters,
        |r| &r.series,
    )?;
    process_rel_pair_file(
        &base.join("character-character.json"),
        &removed,
        &added,
        |r| &r.characters,
        |r| &r.characters,
    )?;
    process_rel_pair_file(
        &base.join("series-series.json"),
        &removed,
        &added,
        |r| &r.series,
        |r| &r.series,
    )?;

    Ok(IndexSyncStats {
        added_or_updated: added.len() as u32,
        removed: removed.len() as u32,
        total_unique_tags,
        elapsed_ms: started.elapsed().as_millis() as u64,
    })
}

/// FRB 엔트리포인트: 변경 전/후 레코드 JSON을 받아 로컬 11종 태그 인덱스를 증분 갱신합니다.
pub fn apply_index_delta(
    data_dir: String,
    removed_rows_json: String,
    added_rows_json: String,
) -> Result<IndexSyncStats, String> {
    apply_index_delta_sync(&data_dir, &removed_rows_json, &added_rows_json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn incremental_index_delta_adds_updates_and_removes_cleanly() {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("violet-idx-sync-{nanos}"));
        let dir_str = dir.to_string_lossy().to_string();

        let add1 = r#"[
            {"Id":1,"Tags":"|female:elf|full color|","Artists":"|nishi|","Language":"korean","Type":"doujinshi"},
            {"Id":2,"Tags":"|female:elf|","Artists":"|nishi|","Language":"korean","Type":"manga"}
        ]"#;
        let s1 = apply_index_delta_sync(&dir_str, "[]", add1).unwrap();
        assert_eq!(s1.added_or_updated, 2);

        let idx: MainIndexJson = load_json_or_missing(&dir.join("index.json")).unwrap();
        assert_eq!(idx.tag.get("female:elf"), Some(&2));
        assert_eq!(idx.tag.get("full color"), Some(&1));
        assert_eq!(idx.artist.get("nishi"), Some(&2));

        let rem2 = r#"[
            {"Id":1,"Tags":"|female:elf|full color|","Artists":"|nishi|","Language":"korean","Type":"doujinshi"},
            {"Id":2,"Tags":"|female:elf|","Artists":"|nishi|","Language":"korean","Type":"manga"}
        ]"#;
        let add2 = r#"[
            {"Id":1,"Tags":"|female:elf|male:sole male|","Artists":"|nishi|","Language":"korean","Type":"doujinshi"}
        ]"#;
        apply_index_delta_sync(&dir_str, rem2, add2).unwrap();

        let idx2: MainIndexJson = load_json_or_missing(&dir.join("index.json")).unwrap();
        assert_eq!(idx2.tag.get("female:elf"), Some(&1));
        assert_eq!(idx2.tag.get("full color"), None);
        assert_eq!(idx2.tag.get("male:sole male"), Some(&1));
        assert_eq!(idx2.artist.get("nishi"), Some(&1));

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn corrupted_json_index_returns_err_and_preserves_existing_file() {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("violet-idx-corrupt-{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        let corrupt = "{not-valid-json";
        let index_path = dir.join("index.json");
        fs::write(&index_path, corrupt).unwrap();

        let add = r#"[{"Id":1,"Tags":"|female:elf|","Language":"korean"}]"#;
        let err = apply_index_delta_sync(&dir.to_string_lossy(), "[]", add).unwrap_err();
        assert!(err.contains("corrupted json"));
        assert_eq!(fs::read_to_string(&index_path).unwrap(), corrupt);

        let _ = fs::remove_dir_all(dir);
    }
}