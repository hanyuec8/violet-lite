// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Bounded disk scans and the two-buffer reader/scorer handoff.

use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::sync::atomic::Ordering as AtomicOrdering;

use super::mobile::{MobileStore, Scope, MIB};
use super::source::{Source, SourceFormat, SourceV2};
use super::{
    invalid_data, BlockEntryV2, FlatRecord, MessageBlock, MessageMeta, TextRange, FLAT_RECORD_LEN,
    HEADER_LEN,
};

const METADATA_CHECK_INTERVAL: usize = 65_536;

impl MobileStore {
    pub(crate) fn scan_metadata(
        &self,
        mut visit: impl FnMut(usize, FlatRecord) -> io::Result<()>,
    ) -> io::Result<()> {
        let mut base = 0usize;
        for source in &self.sources {
            if source.count == 0 {
                continue;
            }
            if !matches!(source.format, SourceFormat::V1 { .. }) {
                base += source.count;
                continue;
            }
            let mut file = BufReader::with_capacity(MIB, File::open(&source.path)?);
            file.seek(SeekFrom::Start(HEADER_LEN))?;
            for index in 0..source.count {
                if index % METADATA_CHECK_INTERVAL == 0 {
                    self.check_cancel()?;
                }
                let record = FlatRecord::read_from(&mut file)?;
                record.validate(source.bytes)?;
                visit(base + index, record)?;
                if index % METADATA_CHECK_INTERVAL == 0 {
                    self.scanned.store(base + index, AtomicOrdering::Relaxed);
                    if index > 0 {
                        release_pages(
                            file.get_ref(),
                            HEADER_LEN
                                + (index - METADATA_CHECK_INTERVAL) as u64 * FLAT_RECORD_LEN as u64,
                            METADATA_CHECK_INTERVAL as u64 * FLAT_RECORD_LEN as u64,
                        );
                    }
                }
            }
            base += source.count;
            release_pages(
                file.get_ref(),
                HEADER_LEN,
                source.count as u64 * FLAT_RECORD_LEN as u64,
            );
        }
        self.scanned.store(self.total, AtomicOrdering::Relaxed);
        Ok(())
    }

    pub(crate) fn scan_scoped(
        &self,
        scope: &Scope,
        mut visit: impl FnMut(usize, &MessageBlock) -> io::Result<()>,
    ) -> io::Result<()> {
        let planned_total = self.estimate_planned_records(scope);
        self.planned.store(planned_total, AtomicOrdering::Relaxed);
        if planned_total == 0 {
            return Ok(());
        }

        std::thread::scope(|threads| {
            let (ready_sender, ready_blocks) =
                std::sync::mpsc::sync_channel::<(usize, MessageBlock)>(0);
            let (empty_sender, empty_blocks) = std::sync::mpsc::sync_channel::<MessageBlock>(1);
            empty_sender.send(MessageBlock::default()).unwrap();

            let producer = threads.spawn(move || {
                self.read_blocks_scoped(scope, |base, block| {
                    ready_sender.send((base, block)).map_err(|_| {
                        io::Error::new(io::ErrorKind::Interrupted, "scan consumer stopped")
                    })?;
                    empty_blocks.recv().map_err(|_| {
                        io::Error::new(io::ErrorKind::Interrupted, "scan consumer stopped")
                    })
                })
            });

            let scoring_result: io::Result<()> = (|| {
                for (base, block) in &ready_blocks {
                    self.check_cancel()?;
                    visit(base, &block)?;
                    self.scanned
                        .fetch_add(block.messages.len(), AtomicOrdering::Relaxed);
                    let _ = empty_sender.send(block);
                }
                Ok(())
            })();

            drop(ready_blocks);
            drop(empty_sender);

            let reader_result = producer
                .join()
                .map_err(|_| io::Error::other("mobile block reader panicked"))?;

            match (scoring_result, reader_result) {
                (Err(err), _) => Err(err),
                (Ok(()), Err(err)) if err.kind() != io::ErrorKind::Interrupted => Err(err),
                (Ok(()), Err(err)) => {
                    self.check_cancel()?;
                    Err(err)
                }
                (Ok(()), Ok(())) => Ok(()),
            }
        })
    }

    fn estimate_planned_records(&self, scope: &Scope) -> usize {
        let mut total = 0usize;
        for source in &self.sources {
            if source.count == 0 {
                continue;
            }
            match &source.format {
                SourceFormat::V1 { .. } => total += source.count,
                SourceFormat::V2(v2) => match scope {
                    Scope::Article(aid) => {
                        if let Some(entry) = v2.find_article(*aid) {
                            let sb = v2.locate_block(entry.start_record as usize).map(|b| b.0);
                            let eb = v2
                                .locate_block((entry.start_record + entry.record_count).saturating_sub(1) as usize)
                                .map(|b| b.0);
                            if let (Some(sb), Some(eb)) = (sb, eb) {
                                for b in &v2.blocks[sb..=eb] {
                                    total += b.record_count as usize;
                                }
                            }
                        }
                    }
                    _ => {
                        for b in &v2.blocks {
                            if block_matches_scope(b, scope) {
                                total += b.record_count as usize;
                            }
                        }
                    }
                },
            }
        }
        total
    }

    fn read_blocks_scoped(
        &self,
        scope: &Scope,
        mut handoff: impl FnMut(usize, MessageBlock) -> io::Result<MessageBlock>,
    ) -> io::Result<()> {
        let mut block = MessageBlock::default();
        let mut global_base = 0usize;

        for source in &self.sources {
            if source.count == 0 {
                continue;
            }
            match &source.format {
                SourceFormat::V1 { text_start } => {
                    let mut reader = BlockReader::open(self, source)?;
                    while reader.next_record < source.count {
                        self.check_cancel()?;
                        let first_in_source = reader.next_record;
                        let text_range = reader.fill_metadata(&mut block)?;
                        let count_in_block = block.messages.len();
                        reader.next_record += count_in_block;

                        if !block.message_bytes.is_empty() {
                            reader
                                .text
                                .seek(SeekFrom::Start(*text_start + text_range.start))?;
                            reader.text.read_exact(&mut block.message_bytes)?;
                            validate_block_text(&mut block, text_range.start)?;
                            release_pages(
                                &reader.text,
                                *text_start + text_range.start,
                                text_range.end - text_range.start,
                            );
                        } else {
                            for meta in &mut block.messages {
                                meta.message.offset = 0;
                            }
                        }

                        release_pages(
                            reader.metadata.get_ref(),
                            HEADER_LEN + first_in_source as u64 * FLAT_RECORD_LEN as u64,
                            count_in_block as u64 * FLAT_RECORD_LEN as u64,
                        );

                        block = handoff(global_base + first_in_source, block)?;
                    }
                }
                SourceFormat::V2(v2) => {
                    block = self.read_v2_blocks_scoped(
                        source,
                        v2,
                        scope,
                        global_base,
                        block,
                        &mut handoff,
                    )?;
                }
            }
            global_base += source.count;
        }
        Ok(())
    }

    fn read_v2_blocks_scoped(
        &self,
        source: &Source,
        v2: &SourceV2,
        scope: &Scope,
        global_base: usize,
        mut block: MessageBlock,
        handoff: &mut impl FnMut(usize, MessageBlock) -> io::Result<MessageBlock>,
    ) -> io::Result<MessageBlock> {
        if v2.blocks.is_empty() {
            return Ok(block);
        }
        let mut file = File::open(&source.path)?;
        let range = match scope {
            Scope::Article(aid) => match v2.find_article(*aid) {
                Some(entry) => {
                    let sb = v2.locate_block(entry.start_record as usize).map(|b| b.0).unwrap_or(0);
                    let eb = v2
                        .locate_block((entry.start_record + entry.record_count).saturating_sub(1) as usize)
                        .map(|b| b.0)
                        .unwrap_or(sb);
                    sb..=eb
                }
                None => return Ok(block),
            },
            _ => 0..=(v2.blocks.len() - 1),
        };

        for blk in &v2.blocks[range] {
            self.check_cancel()?;
            if !block_matches_scope(blk, scope) {
                continue;
            }
            v2.read_hot_block(&mut file, blk, &mut block)?;
            release_pages(&file, blk.hot_offset, u64::from(blk.hot_len));
            block = handoff(global_base + blk.first_record as usize, block)?;
        }
        Ok(block)
    }
}

#[inline]
fn block_matches_scope(blk: &BlockEntryV2, scope: &Scope) -> bool {
    match scope {
        Scope::All => true,
        Scope::Article(id) => blk.first_article_id <= *id && *id <= blk.last_article_id,
        Scope::Range(min, max) => blk.last_article_id >= *min && blk.first_article_id <= *max,
        Scope::Many(sorted_ids) => {
            if sorted_ids.is_empty() {
                return false;
            }
            let pos = sorted_ids.partition_point(|&id| id < blk.first_article_id);
            pos < sorted_ids.len() && sorted_ids[pos] <= blk.last_article_id
        }
    }
}

struct BlockReader<'a> {
    store: &'a MobileStore,
    source: &'a Source,
    metadata: BufReader<File>,
    text: File,
    next_record: usize,
    pending_record: Option<FlatRecord>,
}

impl<'a> BlockReader<'a> {
    fn open(store: &'a MobileStore, source: &'a Source) -> io::Result<Self> {
        let mut metadata = BufReader::with_capacity(MIB, File::open(&source.path)?);
        metadata.seek(SeekFrom::Start(HEADER_LEN))?;
        let text = File::open(&source.path)?;
        Ok(Self {
            store,
            source,
            metadata,
            text,
            next_record: 0,
            pending_record: None,
        })
    }

    fn fill_metadata(&mut self, block: &mut MessageBlock) -> io::Result<std::ops::Range<u64>> {
        let remaining = self.source.count - self.next_record;
        block.messages.clear();
        block
            .messages
            .reserve(self.store.record_limit.min(remaining));
        let mut text_start = u64::MAX;
        let mut text_end = 0u64;

        while block.messages.len() < remaining && block.messages.len() < self.store.record_limit {
            if block.messages.len() % METADATA_CHECK_INTERVAL == 0 {
                self.store.check_cancel()?;
            }
            let record = match self.pending_record.take() {
                Some(r) => r,
                None => FlatRecord::read_from(&mut self.metadata)?,
            };
            record.validate(self.source.bytes)?;
            if !record.correct.is_finite() {
                return Err(invalid_data("non-finite correctness"));
            }
            let extended_start = text_start.min(record.message_offset);
            let extended_end = text_end.max(record.message_offset + u64::from(record.message_len));
            if extended_end - extended_start > self.store.text_limit as u64 {
                if block.messages.is_empty() {
                    return Err(invalid_data("message exceeds mobile text buffer"));
                }
                self.pending_record = Some(record);
                break;
            }
            text_start = extended_start;
            text_end = extended_end;
            block.messages.push(MessageMeta {
                article_id: record.article_id,
                page: record.page,
                message: TextRange {
                    offset: record.message_offset,
                    len: record.message_len,
                },
                correct: record.correct,
                rects: record.rects,
            });
        }

        if text_start == u64::MAX {
            block.message_bytes.clear();
            return Ok(0..0);
        }
        let length = (text_end - text_start) as usize;
        block.message_bytes.resize(length, 0);
        Ok(text_start..text_end)
    }
}

pub(crate) fn validate_block_text(block: &mut MessageBlock, low: u64) -> io::Result<()> {
    let text = std::str::from_utf8(&block.message_bytes).ok();
    for meta in &mut block.messages {
        meta.message.offset -= low;
        let start = meta.message.offset as usize;
        let end = start + meta.message.len as usize;
        if let Some(valid_str) = text {
            if !valid_str.is_char_boundary(start) || !valid_str.is_char_boundary(end) {
                return Err(invalid_data("invalid message UTF-8 boundary"));
            }
        } else {
            std::str::from_utf8(&block.message_bytes[start..end])
                .map_err(|_| invalid_data("invalid message UTF-8"))?;
        }
    }
    Ok(())
}

fn release_pages(file: &File, offset: u64, length: u64) {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::fd::AsRawFd;
        if length > 0 && offset <= i64::MAX as u64 && length <= i64::MAX as u64 {
            unsafe {
                libc::posix_fadvise(
                    file.as_raw_fd(),
                    offset as _,
                    length as _,
                    libc::POSIX_FADV_DONTNEED,
                );
            }
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let _ = (file, offset, length);
}