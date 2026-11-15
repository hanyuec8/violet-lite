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

pub async fn decompress_7z(src: String, dest: String) {
    if let Err(e) = sevenz_rust::decompress_file_with_extract_fn(&src, &dest, to_parent_entry_extract_fn) {
        eprintln!("[Rust decompress_7z] Decompression failed: {e}");
    }
}

/// 단일 .7z 아카이브(예: merged-ko.fscm.7z)를 지정 폴더에 평탄화 추출하고 추출된 파일 경로 목록을 반환합니다.
pub async fn decompress_7z_flat(src: String, dest_dir: String) -> Result<Vec<String>, String> {
    extract_7z_flat_to_dir(&src, &dest_dir)
}

#[cfg(test)]
mod tests {
    use super::decompress_7z;

    #[test]
    fn test_decompress() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                decompress_7z(
                    "../test/rawdata-korean.7z".to_string(),
                    "../test/rawdata".to_string(),
                )
                .await;
            });
    }
}
