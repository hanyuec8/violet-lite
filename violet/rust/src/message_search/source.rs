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

const MAX_V2_DECOMPRESSED_BLOCK_BYTES: usize = 128 * 1024 * 1024;

fn read_u16_le(buf: &[u8], off: usize) -> io::Result<u16> {
    let end = off
        .checked_add(2)
        .ok_or_else(|| invalid_data("FSCM V2 u16 offset overflow"))?;
    let slice = buf
        .get(off..end)
        .ok_or_else(|| invalid_data("FSCM V2 truncated u16"))?;
    Ok(u16::from_le_bytes([slice[0], slice[1]]))
}

fn read_u32_le(buf: &[u8], off: usize) -> io::Result<u32> {
    let end = off
        .checked_add(4)
        .ok_or_else(|| invalid_data("FSCM V2 u32 offset overflow"))?;
    let slice = buf
        .get(off..end)
        .ok_or_else(|| invalid_data("FSCM V2 truncated u32"))?;
    Ok(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_u64_le(buf: &[u8], off: usize) -> io::Result<u64> {
    let end = off
        .checked_add(8)
        .ok_or_else(|| invalid_data("FSCM V2 u64 offset overflow"))?;
    let slice = buf
        .get(off..end)
        .ok_or_else(|| invalid_data("FSCM V2 truncated u64"))?;
    Ok(u64::from_le_bytes([
        slice[0], slice[1], slice[2], slice[3], slice[4], slice[5], slice[6], slice[7],
    ]))
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
            let raw_len = blk.hot_raw_len as usize;
            if raw_len > MAX_V2_DECOMPRESSED_BLOCK_BYTES {
                return Err(invalid_data("FSCM V2 hot block exceeds max size"));
            }
            lz4_flex::decompress(&stored, raw_len)
                .map_err(|_| invalid_data("FSCM V2 hot LZ4 decompression failed"))?
        } else {
            stored
        };
        if raw.len() < 4 {
            return Err(invalid_data("FSCM V2 hot block truncated"));
        }
        let n = blk.record_count as usize;
        let run_count = read_u32_le(&raw, 0)? as usize;
        let run_bytes = run_count
            .checked_mul(8)
            .ok_or_else(|| invalid_data("run overflow"))?;
        let runs_end = 4usize
            .checked_add(run_bytes)
            .ok_or_else(|| invalid_data("run overflow"))?;
        let pages_bytes = n
            .checked_mul(2)
            .ok_or_else(|| invalid_data("pages overflow"))?;
        let pages_end = runs_end
            .checked_add(pages_bytes)
            .ok_or_else(|| invalid_data("pages overflow"))?;
        let corrects_end = pages_end
            .checked_add(n)
            .ok_or_else(|| invalid_data("corrects overflow"))?;
        let lens_end = corrects_end
            .checked_add(pages_bytes)
            .ok_or_else(|| invalid_data("lens overflow"))?;
        if raw.len() < lens_end {
            return Err(invalid_data("FSCM V2 hot metadata truncated"));
        }

        out.messages.clear();
        out.messages.reserve(n);
        out.message_bytes.clear();

        let mut text_cursor = 0u64;
        let mut rec_i = 0usize;
        for r in 0..run_count {
            let run_off = 4 + r * 8;
            let aid = read_u32_le(&raw, run_off)?;
            let cnt = read_u32_le(&raw, run_off + 4)? as usize;
            let end_rec = rec_i
                .checked_add(cnt)
                .ok_or_else(|| invalid_data("FSCM V2 run count overflow"))?;
            if end_rec > n {
                return Err(invalid_data("FSCM V2 run count mismatch"));
            }
            for _ in 0..cnt {
                let page = u32::from(read_u16_le(&raw, runs_end + rec_i * 2)?);
                let correct_byte = *raw
                    .get(pages_end + rec_i)
                    .ok_or_else(|| invalid_data("FSCM V2 correct out of bounds"))?;
                let correct = dequantize_correct_f32(correct_byte);
                let len = read_u16_le(&raw, corrects_end + rec_i * 2)?;
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
                text_cursor = text_cursor
                    .checked_add(u64::from(len))
                    .ok_or_else(|| invalid_data("FSCM V2 text cursor overflow"))?;
                rec_i += 1;
            }
        }
        if rec_i != n {
            return Err(invalid_data("FSCM V2 record count mismatch"));
        }
        let arena_slice = raw
            .get(lens_end..)
            .ok_or_else(|| invalid_data("FSCM V2 arena out of bounds"))?;
        if u64::try_from(arena_slice.len()).ok() != Some(text_cursor) {
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
        let expected = (blk.record_count as usize)
            .checked_mul(8)
            .ok_or_else(|| invalid_data("FSCM V2 cold size overflow"))?;
        let raw = if (self.flags & V2_FLAG_LZ4_COLD) != 0 {
            let raw_len = blk.cold_raw_len as usize;
            if raw_len > MAX_V2_DECOMPRESSED_BLOCK_BYTES {
                return Err(invalid_data("FSCM V2 cold block exceeds max size"));
            }
            lz4_flex::decompress(&stored, raw_len)
                .map_err(|_| invalid_data("FSCM V2 cold LZ4 decompression failed"))?
        } else {
            stored
        };
        if raw.len() != expected {
            return Err(invalid_data("FSCM V2 cold length mismatch"));
        }
        Ok(raw)
    }

    pub fn cold_rect_at(
        cold_raw: &[u8],
        record_count: usize,
        local_idx: usize,
    ) -> io::Result<[f32; 4]> {
        if local_idx >= record_count {
            return Err(invalid_data("FSCM V2 cold local index out of bounds"));
        }
        let mut xywh = [0u16; 4];
        for (col, slot) in xywh.iter_mut().enumerate() {
            let elem = col
                .checked_mul(record_count)
                .and_then(|base| base.checked_add(local_idx))
                .and_then(|idx| idx.checked_mul(2))
                .ok_or_else(|| invalid_data("FSCM V2 cold offset overflow"))?;
            *slot = read_u16_le(cold_raw, elem)?;
        }
        Ok(dequantize_rects_xywh(xywh))
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
                .checked_add(
                    (article_count as u64)
                        .checked_mul(V2_ARTICLE_ENTRY_LEN as u64)
                        .ok_or_else(|| invalid_data("FSCM V2 article table overflow"))?,
                )
                .and_then(|v| {
                    v.checked_add(
                        (block_count as u64)
                            .checked_mul(V2_BLOCK_ENTRY_LEN as u64)
                            .ok_or_else(|| invalid_data("FSCM V2 block table overflow"))
                            .ok()?,
                    )
                })
                .ok_or_else(|| invalid_data("FSCM V2 directory overflow"))?;
            if dir_end > file_len {
                return Err(invalid_data("FSCM V2 directory exceeds file length"));
            }

            let mut art_buf = vec![0u8; article_count * V2_ARTICLE_ENTRY_LEN];
            file.read_exact(&mut art_buf)?;
            let mut articles = Vec::with_capacity(article_count);
            for i in 0..article_count {
                let o = i * V2_ARTICLE_ENTRY_LEN;
                articles.push(ArticleEntryV2 {
                    article_id: read_u32_le(&art_buf, o)?,
                    start_record: read_u32_le(&art_buf, o + 4)?,
                    record_count: read_u32_le(&art_buf, o + 8)?,
                });
            }

            let mut blk_buf = vec![0u8; block_count * V2_BLOCK_ENTRY_LEN];
            file.read_exact(&mut blk_buf)?;
            let mut blocks = Vec::with_capacity(block_count);
            let mut hot_total_raw = 0u64;
            for i in 0..block_count {
                let o = i * V2_BLOCK_ENTRY_LEN;
                let b = BlockEntryV2 {
                    first_article_id: read_u32_le(&blk_buf, o)?,
                    last_article_id: read_u32_le(&blk_buf, o + 4)?,
                    first_record: read_u32_le(&blk_buf, o + 8)?,
                    record_count: read_u32_le(&blk_buf, o + 12)?,
                    hot_offset: read_u64_le(&blk_buf, o + 16)?,
                    hot_len: read_u32_le(&blk_buf, o + 24)?,
                    hot_raw_len: read_u32_le(&blk_buf, o + 28)?,
                    cold_offset: read_u64_le(&blk_buf, o + 32)?,
                    cold_len: read_u32_le(&blk_buf, o + 40)?,
                    cold_raw_len: read_u32_le(&blk_buf, o + 44)?,
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
                    let msg = cached_hot
                        .try_get(local_idx)
                        .ok_or_else(|| invalid_data("FSCM V2 hot record invalid"))?;
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
                    let rects = SourceV2::cold_rect_at(&cached_cold, blk.record_count as usize, local_idx)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn v2_corrupt_hot_block_and_cold_rect_fail_without_panicking() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("violet-corrupt-v2-{nanos}.fscm"));

        // 1 block claiming record_count = u32::MAX with 8-byte hot payload -> must return Err, not panic
        let mut f = File::create(&path).unwrap();
        f.write_all(FLAT_V2_MAGIC).unwrap();
        f.write_all(&FLAT_V2_VERSION.to_le_bytes()).unwrap();
        f.write_all(&0u32.to_le_bytes()).unwrap();
        f.write_all(&1u64.to_le_bytes()).unwrap(); // total_records
        f.write_all(&1u32.to_le_bytes()).unwrap(); // block_count
        f.write_all(&0u32.to_le_bytes()).unwrap(); // article_count

        let hot_offset = V2_HEADER_LEN + V2_BLOCK_ENTRY_LEN as u64;
        let hot_payload = [0u8; 8];
        let cold_offset = hot_offset + hot_payload.len() as u64;
        // BlockEntryV2 (48 bytes)
        f.write_all(&1u32.to_le_bytes()).unwrap();
        f.write_all(&1u32.to_le_bytes()).unwrap();
        f.write_all(&0u32.to_le_bytes()).unwrap();
        f.write_all(&u32::MAX.to_le_bytes()).unwrap(); // corrupted record_count
        f.write_all(&hot_offset.to_le_bytes()).unwrap();
        f.write_all(&(hot_payload.len() as u32).to_le_bytes()).unwrap();
        f.write_all(&(hot_payload.len() as u32).to_le_bytes()).unwrap();
        f.write_all(&cold_offset.to_le_bytes()).unwrap();
        f.write_all(&0u32.to_le_bytes()).unwrap();
        f.write_all(&0u32.to_le_bytes()).unwrap();
        f.write_all(&hot_payload).unwrap();
        drop(f);

        let src = Source::open(&path).unwrap();
        let SourceFormat::V2(v2) = &src.format else {
            panic!("expected V2");
        };
        let mut reader = File::open(&path).unwrap();
        let mut blk_out = MessageBlock::default();
        let err = v2.read_hot_block(&mut reader, &v2.blocks[0], &mut blk_out).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(SourceV2::cold_rect_at(&[0u8; 4], 4, 2).is_err());

        let _ = std::fs::remove_file(path);
    }
}