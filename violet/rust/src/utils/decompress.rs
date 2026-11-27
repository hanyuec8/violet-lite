// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

use std::{
    fs::File,
    io::{copy, BufWriter, Read, Write},
    path::PathBuf,
};

use sevenz_rust::{Error, SevenZArchiveEntry};

pub fn to_parent_entry_extract_fn(
    entry: &SevenZArchiveEntry,
    reader: &mut dyn Read,
    dest: &PathBuf,
) -> Result<bool, Error> {
    if entry.is_directory() {
        if !dest.exists() {
            std::fs::create_dir_all(dest).map_err(Error::io)?;
        }
        return Ok(true);
    }

    let path = dest;
    if let Some(p) = path.parent() {
        if !p.exists() {
            std::fs::create_dir_all(p).map_err(Error::io)?;
        }
    }

    // extract to parent directory safely without panicking on unwrap()
    let file_name = match path.file_name() {
        Some(name) => name,
        None => return Err(Error::other("Invalid archive entry file name")),
    };

    let target_parent = path
        .parent()
        .and_then(|p| p.parent())
        .or_else(|| path.parent())
        .unwrap_or(path.as_path());

    if !target_parent.exists() {
        std::fs::create_dir_all(target_parent).map_err(Error::io)?;
    }

    let to_path = target_parent.join(file_name);

    let file = File::create(&to_path)
        .map_err(|e| Error::Io(e, to_path.to_string_lossy().to_string().into()))?;
    if entry.size() == 0 {
        return Ok(true);
    }

    let mut writer = BufWriter::with_capacity(64 * 1024, file);
    copy(reader, &mut writer).map_err(Error::io)?;
    writer.flush().map_err(Error::io)?;

    Ok(true)
}

/// 아카이브 내부 경로 구조와 무관하게 파일명만 추출하여 `dest_dir` 직하위에 안전하게 풀어냅니다.
pub fn extract_7z_flat_to_dir(src: &str, dest_dir: &str) -> Result<Vec<String>, String> {
    let out_dir = PathBuf::from(dest_dir);
    if !out_dir.exists() {
        std::fs::create_dir_all(&out_dir)
            .map_err(|e| format!("Failed to create destination dir '{dest_dir}': {e}"))?;
    }

    let mut extracted_files = Vec::new();
    let target_dir = out_dir.clone();

    sevenz_rust::decompress_file_with_extract_fn(src, &out_dir, |entry, reader, _dest| {
        if entry.is_directory() {
            return Ok(true);
        }
        let raw_name = PathBuf::from(entry.name());
        let file_name = match raw_name.file_name() {
            Some(name) => name,
            None => return Err(Error::other("Invalid 7z entry file name")),
        };
        let to_path = target_dir.join(file_name);
        let file = File::create(&to_path)
            .map_err(|e| Error::Io(e, to_path.to_string_lossy().to_string().into()))?;
        if entry.size() > 0 {
            let mut writer = BufWriter::with_capacity(256 * 1024, file);
            copy(reader, &mut writer).map_err(Error::io)?;
            writer.flush().map_err(Error::io)?;
        }
        extracted_files.push(to_path.to_string_lossy().to_string());
        Ok(true)
    })
    .map_err(|e| format!("7z extraction failed: {e}"))?;

    Ok(extracted_files)
}
