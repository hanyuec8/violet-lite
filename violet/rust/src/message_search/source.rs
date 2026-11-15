// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! FSCM header validation and final-hit materialization.
//! Ported from `project-violet/violet/violet-message-search/src/message/mobile/source.rs`.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use super::mobile::{MaterializedHit, MobileStore};
use super::{
    dequantize_correct_f32, dequantize_rects_xywh, invalid_data, response_text, ArticleEntryV2,
    BlockEntryV2, FlatRecord, MessageBlock, MessageMeta, ScoredMessage, TextRange, FLAT_FLAG_RAW,
    FLAT_MAGIC, FLAT_RECORD_LEN, FLAT_V2_MAGIC, FLAT_V2_VERSION, FLAT_VERSION, HEADER_LEN,
    V2_ARTICLE_ENTRY_LEN, V2_BLOCK_ENTRY_LEN, V2_FLAG_LZ4_COLD, V2_FLAG_LZ4_HOT, V2_HEADER_LEN,
};

pub struct SourceV2 {
    pub flags: u32,
    pub articles: Vec<ArticleEntryV2>,
    pub blocks: Vec<BlockEntryV2>,
}

pub enum SourceFormat {
    V1 { text_start: u64 },
    V2(SourceV2),
}

pub struct Source {
    pub path: PathBuf,
    pub count: usize,
    pub bytes: u64,
    pub max_article_id: u32,
    pub has_raw_flag: bool,
    pub format: SourceFormat,
}

fn read_u32(file: &mut File) -> io::Result<u32> {
    let mut buf = [0u8; 4];
    file.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}

fn read_u64(file: &mut File) -> io::Result<u64> {
    let mut buf = [0u8; 8];
    file.read_exact(&mut buf)?;
    Ok(u64::from_le_bytes(buf))
}

fn read_u32_le(buf: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(buf[off..off + 4].try_into().unwrap())
}

fn read_u64_le(buf: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(buf[off..off + 8].try_into().unwrap())
}

impl SourceV2 {
    pub fn find_article(&self, article_id: u32) -> Option<ArticleEntryV2> {
        self.articles
            .binary_search_by_key(&article_id, |a| a.article_id)
            .ok()
            .map(|idx| self.articles[idx])
    }

    pub fn locate_block(&self, record_index: usize) -> Option<(usize, usize)> {
        let rec_u32 = u32::try_from(record_index).ok()?;
        let idx = self
            .blocks
            .partition_point(|b| b.first_record <= rec_u32)
            .checked_sub(1)?;
        let blk = &self.blocks[idx];
        let local = rec_u32.checked_sub(blk.first_record)?;
        if local < blk.record_count {
            Some((idx, local as usize))
        } else {
            None
        }
    }

    pub fn read_hot_block(
        &self,
        file: &mut File,
        blk: &BlockEntryV2,
        out: &mut MessageBlock,
    ) -> io::Result<()> {
        file.seek(SeekFrom::Start(blk.hot_offset))?;
        let mut stored = vec![0u8; blk.hot_len as usize];
        file.read_exact(&mut stored)?;

        let raw = if (self.flags & V2_FLAG_LZ4_HOT) != 0 {
            lz4_flex::decompress(&stored, blk.hot_raw_len as usize)
                .map_err(|_| invalid_data("FSCM V2 hot LZ4 decompression failed"))?
        } else {
            stored
        };
        if raw.len() < 4 {
            return Err(invalid_data("FSCM V2 hot block truncated"));
        }
        let n = blk.record_count as usize;
        let run_count = read_u32_le(&raw, 0) as usize;
        let runs_end = 4usize
            .checked_add(run_count.checked_mul(8).ok_or_else(|| invalid_data("run overflow"))?)
            .ok_or_else(|| invalid_data("run overflow"))?;
        let pages_end = runs_end + n * 2;
        let corrects_end = pages_end + n;
        let lens_end = corrects_end + n * 2;
        if raw.len() < lens_end {
            return Err(invalid_data("FSCM V2 hot metadata truncated"));
        }

        out.messages.clear();
        out.messages.reserve(n);
        out.message_bytes.clear();

        let mut text_cursor = 0u64;
        let mut rec_i = 0usize;
        for r in 0..run_count {
            let aid = read_u32_le(&raw, 4 + r * 8);
            let cnt = read_u32_le(&raw, 4 + r * 8 + 4) as usize;
            for _ in 0..cnt {
                if rec_i >= n {
                    return Err(invalid_data("FSCM V2 run count mismatch"));
                }
                let p_off = runs_end + rec_i * 2;
                let page = u32::from(u16::from_le_bytes([raw[p_off], raw[p_off + 1]]));
                let correct = dequantize_correct_f32(raw[pages_end + rec_i]);
                let l_off = corrects_end + rec_i * 2;
                let len = u16::from_le_bytes([raw[l_off], raw[l_off + 1]]);
                out.messages.push(MessageMeta {
                    article_id: aid,
                    page,
                    message: TextRange {
                        offset: text_cursor,
                        len: u32::from(len),
                    },
                    correct,
                    rects: [0.0; 4],
                });
                text_cursor += u64::from(len);
                rec_i += 1;
            }
        }
        if rec_i != n {
            return Err(invalid_data("FSCM V2 record count mismatch"));
        }
        let arena_slice = &raw[lens_end..];
        if arena_slice.len() != text_cursor as usize {
            return Err(invalid_data("FSCM V2 text length mismatch"));
        }
        if std::str::from_utf8(arena_slice).is_err() {
            return Err(invalid_data("FSCM V2 invalid UTF-8"));
        }
        out.message_bytes.extend_from_slice(arena_slice);
        Ok(())
    }

    pub fn read_cold_block(&self, file: &mut File, blk: &BlockEntryV2) -> io::Result<Vec<u8>> {
        file.seek(SeekFrom::Start(blk.cold_offset))?;
        let mut stored = vec![0u8; blk.cold_len as usize];
        file.read_exact(&mut stored)?;
        let raw = if (self.flags & V2_FLAG_LZ4_COLD) != 0 {
            lz4_flex::decompress(&stored, blk.cold_raw_len as usize)
                .map_err(|_| invalid_data("FSCM V2 cold LZ4 decompression failed"))?
        } else {
            stored
        };
        let expected = (blk.record_count as usize) * 8;
        if raw.len() != expected {
            return Err(invalid_data("FSCM V2 cold length mismatch"));
        }
        Ok(raw)
    }

    pub fn cold_rect_at(cold_raw: &[u8], record_count: usize, local_idx: usize) -> [f32; 4] {
        let mut xywh = [0u16; 4];
        for col in 0..4 {
            let off = (col * record_count + local_idx) * 2;
            xywh[col] = u16::from_le_bytes([cold_raw[off], cold_raw[off + 1]]);
        }
        dequantize_rects_xywh(xywh)
    }
}

impl Source {
    pub fn open(path: &Path) -> io::Result<Self> {
        let mut file = File::open(path)?;
        let file_len = file.metadata()?.len();
        let mut magic = [0u8; 8];
        file.read_exact(&mut magic)?;
        let version = read_u32(&mut file)?;
        let flags = read_u32(&mut file)?;

        if &magic == FLAT_MAGIC {
            if version != FLAT_VERSION || (flags & !FLAT_FLAG_RAW) != 0 {
                return Err(invalid_data("unsupported FSCM header"));
            }
            let count_u64 = read_u64(&mut file)?;
            let bytes = read_u64(&mut file)?;
            let text_start = count_u64
                .checked_mul(FLAT_RECORD_LEN as u64)
                .and_then(|v| v.checked_add(HEADER_LEN))
                .ok_or_else(|| invalid_data("FSCM size overflow"))?;
            if text_start.checked_add(bytes) != Some(file_len) {
                return Err(invalid_data("FSCM file length mismatch"));
            }
            let count = usize::try_from(count_u64).map_err(|_| invalid_data("too many records"))?;
            let max_article_id = if count > 0 {
                file.seek(SeekFrom::Start(
                    HEADER_LEN + (count as u64 - 1) * FLAT_RECORD_LEN as u64,
                ))?;
                read_u32(&mut file).unwrap_or(0)
            } else {
                0
            };
            return Ok(Self {
                path: path.to_path_buf(),
                count,
                bytes,
                max_article_id,
                has_raw_flag: (flags & FLAT_FLAG_RAW) != 0,
                format: SourceFormat::V1 { text_start },
            });
        }

        if &magic == FLAT_V2_MAGIC {
            if version != FLAT_V2_VERSION || (flags & !(V2_FLAG_LZ4_HOT | V2_FLAG_LZ4_COLD)) != 0 {
                return Err(invalid_data("unsupported FSCM V2 header"));
            }
            let count_u64 = read_u64(&mut file)?;
            let block_count = read_u32(&mut file)? as usize;
            let article_count = read_u32(&mut file)? as usize;
            let count = usize::try_from(count_u64).map_err(|_| invalid_data("too many records"))?;

            let dir_end = V2_HEADER_LEN
                + (article_count as u64) * (V2_ARTICLE_ENTRY_LEN as u64)
                + (block_count as u64) * (V2_BLOCK_ENTRY_LEN as u64);
            if dir_end > file_len {
                return Err(invalid_data("FSCM V2 directory exceeds file length"));
            }

            let mut art_buf = vec![0u8; article_count * V2_ARTICLE_ENTRY_LEN];
            file.read_exact(&mut art_buf)?;
            let mut articles = Vec::with_capacity(article_count);
            for i in 0..article_count {
                let o = i * V2_ARTICLE_ENTRY_LEN;
                articles.push(ArticleEntryV2 {
                    article_id: read_u32_le(&art_buf, o),
                    start_record: read_u32_le(&art_buf, o + 4),
                    record_count: read_u32_le(&art_buf, o + 8),
                });
            }

            let mut blk_buf = vec![0u8; block_count * V2_BLOCK_ENTRY_LEN];
            file.read_exact(&mut blk_buf)?;
            let mut blocks = Vec::with_capacity(block_count);
            let mut hot_total_raw = 0u64;
            for i in 0..block_count {
                let o = i * V2_BLOCK_ENTRY_LEN;
                let b = BlockEntryV2 {
                    first_article_id: read_u32_le(&blk_buf, o),
                    last_article_id: read_u32_le(&blk_buf, o + 4),
                    first_record: read_u32_le(&blk_buf, o + 8),
                    record_count: read_u32_le(&blk_buf, o + 12),
                    hot_offset: read_u64_le(&blk_buf, o + 16),
                    hot_len: read_u32_le(&blk_buf, o + 24),
                    hot_raw_len: read_u32_le(&blk_buf, o + 28),
                    cold_offset: read_u64_le(&blk_buf, o + 32),
                    cold_len: read_u32_le(&blk_buf, o + 40),
                    cold_raw_len: read_u32_le(&blk_buf, o + 44),
                };
                if b.hot_offset.saturating_add(u64::from(b.hot_len)) > file_len
                    || b.cold_offset.saturating_add(u64::from(b.cold_len)) > file_len
                {
                    return Err(invalid_data("FSCM V2 block out of bounds"));
                }
                hot_total_raw += u64::from(b.hot_raw_len);
                blocks.push(b);
            }

            let max_article_id = articles.last().map_or(0, |a| a.article_id);
            return Ok(Self {
                path: path.to_path_buf(),
                count,
                bytes: hot_total_raw,
                max_article_id,
                has_raw_flag: false,
                format: SourceFormat::V2(SourceV2 {
                    flags,
                    articles,
                    blocks,
                }),
            });
        }

        Err(invalid_data("unsupported FSCM header"))
    }

    fn read_record_v1(&self, file: &mut File, index: usize) -> io::Result<FlatRecord> {
        file.seek(SeekFrom::Start(
            HEADER_LEN + index as u64 * FLAT_RECORD_LEN as u64,
        ))?;
        let record = FlatRecord::read_from(file)?;
        record.validate(self.bytes)?;
        Ok(record)
    }

    fn read_raw_or_restored_v1(
        &self,
        file: &mut File,
        text_start: u64,
        record: &FlatRecord,
    ) -> io::Result<String> {
        let (offset, len) = if record.raw_len > 0 {
            (record.raw_offset, record.raw_len)
        } else {
            (record.message_offset, record.message_len)
        };
        let mut bytes = vec![0u8; len as usize];
        file.seek(SeekFrom::Start(text_start + offset))?;
        file.read_exact(&mut bytes)?;
        let text = String::from_utf8(bytes).map_err(|_| invalid_data("invalid raw UTF-8"))?;
        Ok(if record.raw_len > 0 {
            text
        } else {
            response_text(None, &text)
        })
    }
}

impl MobileStore {
    fn locate_record(&self, mut global_index: usize) -> (usize, usize) {
        for (source_index, source) in self.sources.iter().enumerate() {
            if global_index < source.count {
                return (source_index, global_index);
            }
            global_index -= source.count;
        }
        unreachable!("ranked record must belong to a source")
    }

    pub(crate) fn materialize(&self, hits: Vec<ScoredMessage>) -> io::Result<Vec<MaterializedHit>> {
        let mut results = Vec::with_capacity(hits.len());
        let mut raw_total = 0usize;
        let mut handles = self
            .sources
            .iter()
            .map(|s| File::open(&s.path))
            .collect::<io::Result<Vec<_>>>()?;

        let mut cached_v2_key: Option<(usize, usize)> = None;
        let mut cached_hot = MessageBlock::default();
        let mut cached_cold: Vec<u8> = Vec::new();

        for hit in hits {
            self.check_cancel()?;
            let (source_index, record_index) = self.locate_record(hit.index);
            let source = &self.sources[source_index];
            let file = &mut handles[source_index];

            match &source.format {
                SourceFormat::V1 { text_start } => {
                    let record = source.read_record_v1(file, record_index)?;
                    let allowance = if record.raw_len > 0 {
                        record.raw_len as usize
                    } else {
                        (record.message_len as usize)
                            .checked_mul(3)
                            .ok_or_else(|| invalid_data("raw response overflow"))?
                    };
                    let upper_bound = raw_total
                        .checked_add(allowance)
                        .ok_or_else(|| invalid_data("raw response overflow"))?;
                    if upper_bound > self.budget / 16 {
                        return Err(invalid_data("raw response exceeds mobile allowance"));
                    }
                    let raw_text = source.read_raw_or_restored_v1(file, *text_start, &record)?;
                    raw_total += raw_text.len();

                    results.push(MaterializedHit {
                        article_id: record.article_id,
                        page: record.page,
                        correctness: record.correct,
                        match_score: hit.score,
                        rects: record.rects,
                        raw_text,
                    });
                }
                SourceFormat::V2(v2) => {
                    let (blk_idx, local_idx) = v2
                        .locate_block(record_index)
                        .ok_or_else(|| invalid_data("FSCM V2 hit index out of bounds"))?;
                    let blk = &v2.blocks[blk_idx];
                    if cached_v2_key != Some((source_index, blk_idx)) {
                        v2.read_hot_block(file, blk, &mut cached_hot)?;
                        cached_cold = v2.read_cold_block(file, blk)?;
                        cached_v2_key = Some((source_index, blk_idx));
                    }
                    let msg = cached_hot.get(local_idx);
                    let allowance = msg
                        .message
                        .len()
                        .checked_mul(3)
                        .ok_or_else(|| invalid_data("raw response overflow"))?;
                    let upper_bound = raw_total
                        .checked_add(allowance)
                        .ok_or_else(|| invalid_data("raw response overflow"))?;
                    if upper_bound > self.budget / 16 {
                        return Err(invalid_data("raw response exceeds mobile allowance"));
                    }
                    let raw_text = response_text(None, msg.message);
                    raw_total += raw_text.len();
                    let rects = SourceV2::cold_rect_at(&cached_cold, blk.record_count as usize, local_idx);
                    results.push(MaterializedHit {
                        article_id: msg.article_id,
                        page: msg.page,
                        correctness: msg.correct,
                        match_score: hit.score,
                        rects,
                        raw_text,
                    });
                }
            }
        }
        Ok(results)
    }
}