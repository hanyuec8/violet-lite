// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

use crate::utils::decompress::{extract_7z_flat_to_dir, to_parent_entry_extract_fn};

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

pub fn decompress_7z(src: String, dest: String) -> Result<(), String> {
    sevenz_rust::decompress_file_with_extract_fn(&src, &dest, to_parent_entry_extract_fn)
        .map_err(|e| format!("7z decompression failed: {e}"))
}

/// 단일 .7z 아카이브(예: merged-ko.fscm.7z)를 지정 폴더에 평탄화 추출하고 추출된 파일 경로 목록을 반환합니다.
pub fn decompress_7z_flat(src: String, dest_dir: String) -> Result<Vec<String>, String> {
    extract_7z_flat_to_dir(&src, &dest_dir)
}

#[cfg(test)]
mod tests {
    use super::decompress_7z;

    #[test]
    fn test_decompress_if_fixture_present() {
        let src = "../test/rawdata-korean.7z";
        if !std::path::Path::new(src).exists() {
            return;
        }
        decompress_7z(src.to_string(), "../test/rawdata".to_string()).unwrap();
    }

    #[test]
    fn test_decompress_missing_archive_returns_err() {
        let err = decompress_7z(
            "../test/does-not-exist.7z".to_string(),
            "../test/rawdata".to_string(),
        )
        .unwrap_err();
        assert!(err.contains("7z decompression failed"));
    }
}
