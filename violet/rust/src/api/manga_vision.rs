// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

use std::collections::VecDeque;
use std::time::Instant;

use image::imageops::FilterType;
use image::{GrayImage, ImageFormat};
use serde::{Deserialize, Serialize};

/// 1채널 흑백 전처리 결과
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreprocessedMangaPage {
    pub width: u32,
    pub height: u32,
    pub orig_width: u32,
    pub orig_height: u32,
    pub luma_bytes: Vec<u8>,
    pub latency_ms: f64,
}

/// 텍스트 탐지 바운딩 박스 입력
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextBoxInput {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// 말풍선 테두리 흰색 비율 필터링 결과
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilteredBubbleResult {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub is_speech_bubble: bool,
    pub is_inverted: bool,
    pub white_ratio: f64,
    pub black_ratio: f64,
}

/// Zero-AI 글자 지우기 대상 말풍선 영역
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BubbleEraseRegion {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub is_inverted: bool,
}

/// Zero-AI 글자 지우기 결과
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZeroAiEraseResult {
    pub width: u32,
    pub height: u32,
    pub luma_bytes: Vec<u8>,
    pub erased_pixel_count: u64,
    pub preserved_border_components: u32,
    pub latency_ms: f64,
}

/// 1단계: 원본 이미지 바이트를 1채널 그레이스케일(GrayImage)로 디코딩하고 긴 변 상한선으로 리사이징합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn preprocess_manga_grayscale(
    bytes: Vec<u8>,
    max_long_edge: u32,
) -> Option<PreprocessedMangaPage> {
    if bytes.is_empty() {
        return None;
    }

    let start = Instant::now();
    let decoded = image::load_from_memory(&bytes).ok()?;
    let orig_width = decoded.width();
    let orig_height = decoded.height();

    if orig_width == 0 || orig_height == 0 {
        return None;
    }

    let cap = if max_long_edge == 0 { 1600 } else { max_long_edge };
    let long_edge = orig_width.max(orig_height);

    // 1채널 그레이스케일 변환을 먼저 수행해 리사이즈 연산량을 1/3~1/4로 절감
    let gray = decoded.to_luma8();
    let (width, height, luma_bytes) = if long_edge > cap {
        let scale = cap as f64 / long_edge as f64;
        let target_w = ((orig_width as f64 * scale).round() as u32).max(1);
        let target_h = ((orig_height as f64 * scale).round() as u32).max(1);
        let src = gray.as_raw();
        let sw = orig_width as usize;
        let tw = target_w as usize;
        let th = target_h as usize;
        let mut out = vec![0u8; tw * th];
        for y in 0..th {
            let sy = ((y as u64 * orig_height as u64) / target_h as u64) as usize;
            let src_row = sy * sw;
            let dst_row = y * tw;
            for x in 0..tw {
                let sx = ((x as u64 * orig_width as u64) / target_w as u64) as usize;
                out[dst_row + x] = src[src_row + sx];
            }
        }
        (target_w, target_h, out)
    } else {
        (gray.width(), gray.height(), gray.into_raw())
    };

    let latency_ms = start.elapsed().as_secs_f64() * 1000.0;

    Some(PreprocessedMangaPage {
        width,
        height,
        orig_width,
        orig_height,
        luma_bytes,
        latency_ms,
    })
}

/// 2단계: 텍스트 바운딩 박스 외곽 테두리(2~4px 확장 링)의 밝기 히스토그램으로 말풍선과 배경/효과음을 분리합니다.
#[flutter_rust_bridge::frb(sync)]
pub fn filter_speech_bubbles(
    luma_bytes: Vec<u8>,
    width: u32,
    height: u32,
    boxes: Vec<TextBoxInput>,
    border_px: u32,
    min_white_ratio: f64,
    allow_inverted: bool,
) -> Vec<FilteredBubbleResult> {
    if width == 0 || height == 0 || luma_bytes.len() < (width as usize * height as usize) {
        return Vec::new();
    }

    let w = width as i32;
    let h = height as i32;
    let pad = border_px.clamp(1, 16) as i32;
    let threshold_ratio = if min_white_ratio <= 0.0 || min_white_ratio > 1.0 {
        0.75
    } else {
        min_white_ratio
    };

    boxes
        .into_iter()
        .map(|b| {
            let x0 = b.x.clamp(0, w - 1);
            let y0 = b.y.clamp(0, h - 1);
            let x1 = (b.x + b.width).clamp(x0 + 1, w);
            let y1 = (b.y + b.height).clamp(y0 + 1, h);

            let ox0 = (x0 - pad).max(0);
            let oy0 = (y0 - pad).max(0);
            let ox1 = (x1 + pad).min(w);
            let oy1 = (y1 + pad).min(h);

            let mut total_border_pixels: u64 = 0;
            let mut white_pixels: u64 = 0;
            let mut black_pixels: u64 = 0;

            for py in oy0..oy1 {
                let row_offset = py as usize * width as usize;
                for px in ox0..ox1 {
                    // 내부 박스를 제외한 외곽 테두리 링만 샘플링
                    if px >= x0 && px < x1 && py >= y0 && py < y1 {
                        continue;
                    }
                    let val = luma_bytes[row_offset + px as usize];
                    total_border_pixels += 1;
                    if val >= 220 {
                        white_pixels += 1;
                    } else if val <= 35 {
                        black_pixels += 1;
                    }
                }
            }

            let (white_ratio, black_ratio) = if total_border_pixels == 0 {
                (0.0, 0.0)
            } else {
                (
                    white_pixels as f64 / total_border_pixels as f64,
                    black_pixels as f64 / total_border_pixels as f64,
                )
            };

            let is_normal_white = white_ratio >= threshold_ratio;
            let is_inverted = allow_inverted && !is_normal_white && black_ratio >= threshold_ratio;

            FilteredBubbleResult {
                x: b.x,
                y: b.y,
                width: b.width,
                height: b.height,
                is_speech_bubble: is_normal_white || is_inverted,
                is_inverted,
                white_ratio,
                black_ratio,
            }
        })
        .collect()
}

/// 3단계: Zero-AI 고속 글자 지우기 (Connected Components 기반 테두리 선화 보존 + 내부 글자 흰색/검정색 채우기)
#[flutter_rust_bridge::frb(sync)]
pub fn erase_bubble_text_zero_ai(
    mut luma_bytes: Vec<u8>,
    width: u32,
    height: u32,
    regions: Vec<BubbleEraseRegion>,
    dilation_px: u32,
) -> Option<ZeroAiEraseResult> {
    let expected_len = width as usize * height as usize;
    if width == 0 || height == 0 || luma_bytes.len() < expected_len {
        return None;
    }

    let start = Instant::now();
    let img_w = width as i32;
    let img_h = height as i32;
    let dilate = dilation_px.min(6) as i32;

    let mut total_erased: u64 = 0;
    let mut preserved_border_components: u32 = 0;

    for region in regions {
        let x0 = region.x.clamp(0, img_w - 1);
        let y0 = region.y.clamp(0, img_h - 1);
        let x1 = (region.x + region.width).clamp(x0, img_w);
        let y1 = (region.y + region.height).clamp(y0, img_h);

        let cw = (x1 - x0) as usize;
        let ch = (y1 - y0) as usize;
        if cw < 3 || ch < 3 {
            continue;
        }

        let crop_total = cw * ch;
        let mut is_fg = vec![0u8; crop_total];
        let fill_color: u8 = if region.is_inverted { 0 } else { 255 };

        for cy in 0..ch {
            let src_row = (y0 as usize + cy) * width as usize + x0 as usize;
            let dst_row = cy * cw;
            for cx in 0..cw {
                let val = luma_bytes[src_row + cx];
                let fg = if region.is_inverted {
                    val > 55
                } else {
                    val < 200
                };
                if fg {
                    is_fg[dst_row + cx] = 1;
                }
            }
        }

        // 8-방향 Connected Components 탐색
        let mut visited = vec![0u8; crop_total];
        let mut text_mask = vec![0u8; crop_total];
        let mut queue: VecDeque<usize> = VecDeque::new();
        let mut component_indices: Vec<usize> = Vec::new();

        for idx in 0..crop_total {
            if is_fg[idx] == 0 || visited[idx] == 1 {
                continue;
            }

            visited[idx] = 1;
            queue.clear();
            component_indices.clear();
            queue.push_back(idx);
            let mut touches_border = false;

            while let Some(curr) = queue.pop_front() {
                component_indices.push(curr);
                let cx = curr % cw;
                let cy = curr / cw;

                if cx == 0 || cy == 0 || cx + 1 == cw || cy + 1 == ch {
                    touches_border = true;
                }

                let nx_min = cx.saturating_sub(1);
                let nx_max = (cx + 1).min(cw - 1);
                let ny_min = cy.saturating_sub(1);
                let ny_max = (cy + 1).min(ch - 1);

                for ny in ny_min..=ny_max {
                    let row_off = ny * cw;
                    for nx in nx_min..=nx_max {
                        let nidx = row_off + nx;
                        if is_fg[nidx] == 1 && visited[nidx] == 0 {
                            visited[nidx] = 1;
                            queue.push_back(nidx);
                        }
                    }
                }
            }

            if touches_border {
                // 크롭 외곽 경계에 닿은 요소는 말풍선 외곽선/선화로 간주해 보존
                preserved_border_components += 1;
            } else {
                // 내부에 고립된 연결 요소는 글자로 판정해 제거 마스크에 추가
                for &cidx in &component_indices {
                    text_mask[cidx] = 1;
                }
            }
        }

        // 안티앨리어싱 잔상 제거를 위한 마스크 팽창(Dilation) 및 배경색 채우기
        for cy in 0..ch {
            let dst_row = (y0 as usize + cy) * width as usize + x0 as usize;
            for cx in 0..cw {
                let mut should_erase = text_mask[cy * cw + cx] == 1;
                if !should_erase && dilate > 0 {
                    let dy_min = (cy as i32 - dilate).max(0) as usize;
                    let dy_max = (cy as i32 + dilate).min(ch as i32 - 1) as usize;
                    let dx_min = (cx as i32 - dilate).max(0) as usize;
                    let dx_max = (cx as i32 + dilate).min(cw as i32 - 1) as usize;
                    'dilate_loop: for dy in dy_min..=dy_max {
                        let m_row = dy * cw;
                        for dx in dx_min..=dx_max {
                            if text_mask[m_row + dx] == 1 {
                                should_erase = true;
                                break 'dilate_loop;
                            }
                        }
                    }
                }

                if should_erase && luma_bytes[dst_row + cx] != fill_color {
                    luma_bytes[dst_row + cx] = fill_color;
                    total_erased += 1;
                }
            }
        }
    }

    let latency_ms = start.elapsed().as_secs_f64() * 1000.0;

    Some(ZeroAiEraseResult {
        width,
        height,
        luma_bytes,
        erased_pixel_count: total_erased,
        preserved_border_components,
        latency_ms,
    })
}

/// 단일 패스 전처리 + 흰 말풍선 검출 통합 결과 (Dart 중복 디코딩 제거용)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreprocessAndDetectResult {
    pub width: u32,
    pub height: u32,
    pub orig_width: u32,
    pub orig_height: u32,
    pub luma_bytes: Vec<u8>,
    pub bubbles: Vec<TextBoxInput>,
    pub preprocess_ms: f64,
    pub detect_ms: f64,
}

/// 1채널 그레이스케일 버퍼에서 520px 다운샘플링 + 밝은 영역(>=220) BFS로 흰 말풍선 바운딩 박스 검출
#[flutter_rust_bridge::frb(sync)]
pub fn detect_white_bubbles_sync(
    luma_bytes: Vec<u8>,
    width: u32,
    height: u32,
) -> Vec<TextBoxInput> {
    detect_white_bubbles_inner(&luma_bytes, width, height)
}

fn detect_white_bubbles_inner(luma_bytes: &[u8], width: u32, height: u32) -> Vec<TextBoxInput> {
    if width == 0 || height == 0 || luma_bytes.len() < (width as usize * height as usize) {
        return Vec::new();
    }

    const MAX_DIM: u32 = 520;
    let long_edge = width.max(height);
    let scale = if long_edge > MAX_DIM {
        MAX_DIM as f64 / long_edge as f64
    } else {
        1.0
    };
    let sw = ((width as f64 * scale).round() as usize).max(32);
    let sh = ((height as f64 * scale).round() as usize).max(32);
    let total = sw * sh;

    let mut is_bright = vec![0u8; total];
    let mut small_luma = vec![0u8; total];
    for sy in 0..sh {
        let src_y = ((sy as f64 / scale).floor() as usize).min(height as usize - 1);
        let src_row = src_y * width as usize;
        let dst_row = sy * sw;
        for sx in 0..sw {
            let src_x = ((sx as f64 / scale).floor() as usize).min(width as usize - 1);
            let v = luma_bytes[src_row + src_x];
            small_luma[dst_row + sx] = v;
            if v >= 220 {
                is_bright[dst_row + sx] = 1;
            }
        }
    }

    let mut visited = vec![0u8; total];
    let mut queue: VecDeque<usize> = VecDeque::new();
    let mut boxes = Vec::new();

    let min_area = ((total as f64 * 0.0014).round() as usize).clamp(36, 100_000);
    let max_area = (total as f64 * 0.08).round() as usize;

    for idx in 0..total {
        if is_bright[idx] == 0 || visited[idx] == 1 {
            continue;
        }

        visited[idx] = 1;
        queue.clear();
        queue.push_back(idx);

        let mut area = 0usize;
        let mut min_x = sw;
        let mut max_x = 0usize;
        let mut min_y = sh;
        let mut max_y = 0usize;
        let mut touches_outer_border = false;

        while let Some(curr) = queue.pop_front() {
            area += 1;
            let cx = curr % sw;
            let cy = curr / sw;
            if cx < min_x { min_x = cx; }
            if cx > max_x { max_x = cx; }
            if cy < min_y { min_y = cy; }
            if cy > max_y { max_y = cy; }
            if cx == 0 || cx + 1 == sw || cy == 0 || cy + 1 == sh {
                touches_outer_border = true;
            }

            if cx > 0 {
                let n = curr - 1;
                if is_bright[n] == 1 && visited[n] == 0 {
                    visited[n] = 1;
                    queue.push_back(n);
                }
            }
            if cx + 1 < sw {
                let n = curr + 1;
                if is_bright[n] == 1 && visited[n] == 0 {
                    visited[n] = 1;
                    queue.push_back(n);
                }
            }
            if cy > 0 {
                let n = curr - sw;
                if is_bright[n] == 1 && visited[n] == 0 {
                    visited[n] = 1;
                    queue.push_back(n);
                }
            }
            if cy + 1 < sh {
                let n = curr + sw;
                if is_bright[n] == 1 && visited[n] == 0 {
                    visited[n] = 1;
                    queue.push_back(n);
                }
            }
        }

        if area < min_area || area > max_area {
            continue;
        }

        let bw = max_x - min_x + 1;
        let bh = max_y - min_y + 1;
        if bw < 10 || bh < 10 {
            continue;
        }
        // 화면 테두리에 닿은 거대한 여백(패널 간 흰 배경) 및 패널 컷 전체 오인식 차단
        if touches_outer_border && (bw as f64 > sw as f64 * 0.60 || bh as f64 > sh as f64 * 0.60) {
            continue;
        }
        if bw as f64 > sw as f64 * 0.42 && bh as f64 > sh as f64 * 0.32 {
            continue;
        }

        let rect_area = bw * bh;
        let fill_ratio = area as f64 / rect_area.max(1) as f64;
        if fill_ratio < 0.40 {
            continue;
        }

        // 가장자리 12%를 제외한 코어 영역에서 어두운 텍스트 획 비율 검사 (외곽선 노이즈 배제)
        let pad_x = (bw as f64 * 0.12).round() as usize;
        let pad_y = (bh as f64 * 0.12).round() as usize;
        let mut core_pixels = 0usize;
        let mut dark_text_pixels = 0usize;
        for py in (min_y + pad_y)..=(max_y.saturating_sub(pad_y)) {
            let row = py * sw;
            for px in (min_x + pad_x)..=(max_x.saturating_sub(pad_x)) {
                core_pixels += 1;
                if small_luma[row + px] < 135 {
                    dark_text_pixels += 1;
                }
            }
        }
        if core_pixels == 0 {
            continue;
        }
        let dark_ratio = dark_text_pixels as f64 / core_pixels as f64;
        if !(0.02..=0.58).contains(&dark_ratio) {
            continue;
        }

        let inv_scale = 1.0 / scale;
        boxes.push(TextBoxInput {
            x: ((min_x as f64 * inv_scale).floor() as i32).clamp(0, width as i32 - 1),
            y: ((min_y as f64 * inv_scale).floor() as i32).clamp(0, height as i32 - 1),
            width: ((bw as f64 * inv_scale).ceil() as i32).clamp(1, width as i32),
            height: ((bh as f64 * inv_scale).ceil() as i32).clamp(1, height as i32),
        });
    }

    boxes
}

/// 1회 이미지 디코딩 + 1채널 그레이스케일 리사이징 + 흰 말풍선 BFS 검출 통합 파이프라인
#[flutter_rust_bridge::frb(sync)]
pub fn preprocess_and_detect_bubbles_sync(
    bytes: Vec<u8>,
    max_long_edge: u32,
) -> Option<PreprocessAndDetectResult> {
    let prep = preprocess_manga_grayscale(bytes, max_long_edge)?;
    let detect_start = Instant::now();
    let bubbles = detect_white_bubbles_inner(&prep.luma_bytes, prep.width, prep.height);
    let detect_ms = detect_start.elapsed().as_secs_f64() * 1000.0;

    Some(PreprocessAndDetectResult {
        width: prep.width,
        height: prep.height,
        orig_width: prep.orig_width,
        orig_height: prep.orig_height,
        luma_bytes: prep.luma_bytes,
        bubbles,
        preprocess_ms: prep.latency_ms,
        detect_ms,
    })
}

/// Rust에서 외곽 선화를 제거한 단일 텍스트 줄 크롭 (PP-OCRv5 입력용)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CleanedLineCrop {
    pub width: u32,
    pub height: u32,
    pub luma_bytes: Vec<u8>,
}

/// 크롭 경계에 닿은 검은 말풍선 테두리/배경 선화를 8-방향 BFS로 흰색(255) 처리
fn strip_border_artwork_luma(crop: &mut [u8], w: usize, h: usize) {
    if w < 6 || h < 6 {
        return;
    }
    let total = w * h;
    let mut visited = vec![0u8; total];
    let mut queue: VecDeque<usize> = VecDeque::new();

    let mut seed = |x: usize, y: usize| {
        let idx = y * w + x;
        if crop[idx] < 175 && visited[idx] == 0 {
            visited[idx] = 1;
            queue.push_back(idx);
        }
    };

    for x in 0..w {
        seed(x, 0);
        seed(x, h - 1);
    }
    for y in 0..h {
        seed(0, y);
        seed(w - 1, y);
    }

    while let Some(cur) = queue.pop_front() {
        crop[cur] = 255;
        let cx = cur % w;
        let cy = cur / w;
        let ny_min = cy.saturating_sub(1);
        let ny_max = (cy + 1).min(h - 1);
        let nx_min = cx.saturating_sub(1);
        let nx_max = (cx + 1).min(w - 1);
        for ny in ny_min..=ny_max {
            let row = ny * w;
            for nx in nx_min..=nx_max {
                let nidx = row + nx;
                if crop[nidx] < 175 && visited[nidx] == 0 {
                    visited[nidx] = 1;
                    queue.push_back(nidx);
                }
            }
        }
    }
}

/// 말풍선 영역을 잘라 외곽 검은 테두리를 제거한 뒤 Manga-OCR용 224x224 1채널 버퍼로 변환 (Dart 픽셀 루프 0)
#[flutter_rust_bridge::frb(sync)]
pub fn crop_bubble_for_manga_ocr_sync(
    luma_bytes: Vec<u8>,
    width: u32,
    height: u32,
    box_x: i32,
    box_y: i32,
    box_w: i32,
    box_h: i32,
    target_size: u32,
) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || luma_bytes.len() < (width as usize * height as usize) {
        return None;
    }
    let w = width as i32;
    let h = height as i32;
    let x0 = box_x.clamp(0, w - 1) as usize;
    let y0 = box_y.clamp(0, h - 1) as usize;
    let x1 = (box_x + box_w).clamp(x0 as i32 + 1, w) as usize;
    let y1 = (box_y + box_h).clamp(y0 as i32 + 1, h) as usize;
    let cw = x1 - x0;
    let ch = y1 - y0;

    let mut crop = vec![255u8; cw * ch];
    for cy in 0..ch {
        let src_row = (y0 + cy) * width as usize + x0;
        let dst_row = cy * cw;
        crop[dst_row..dst_row + cw].copy_from_slice(&luma_bytes[src_row..src_row + cw]);
    }
    strip_border_artwork_luma(&mut crop, cw, ch);

    let ts = target_size.clamp(32, 512) as usize;
    let mut out = vec![255u8; ts * ts];
    for ty in 0..ts {
        let sy = ((ty as u64 * ch as u64) / ts as u64) as usize;
        let src_row = sy * cw;
        let dst_row = ty * ts;
        for tx in 0..ts {
            let sx = ((tx as u64 * cw as u64) / ts as u64) as usize;
            out[dst_row + tx] = crop[src_row + sx];
        }
    }
    Some(out)
}

/// 말풍선 영역에서 외곽 테두리를 제거하고 가로쓰기 줄 단위로 분할해 반환 (PP-OCRv5 EN/ZH용)
#[flutter_rust_bridge::frb(sync)]
pub fn extract_horizontal_line_crops_sync(
    luma_bytes: Vec<u8>,
    width: u32,
    height: u32,
    box_x: i32,
    box_y: i32,
    box_w: i32,
    box_h: i32,
) -> Vec<CleanedLineCrop> {
    if width == 0 || height == 0 || luma_bytes.len() < (width as usize * height as usize) {
        return Vec::new();
    }
    let w = width as i32;
    let h = height as i32;
    let x0 = box_x.clamp(0, w - 1) as usize;
    let y0 = box_y.clamp(0, h - 1) as usize;
    let x1 = (box_x + box_w).clamp(x0 as i32 + 1, w) as usize;
    let y1 = (box_y + box_h).clamp(y0 as i32 + 1, h) as usize;
    let cw = x1 - x0;
    let ch = y1 - y0;

    let mut crop = vec![255u8; cw * ch];
    for cy in 0..ch {
        let src_row = (y0 + cy) * width as usize + x0;
        let dst_row = cy * cw;
        crop[dst_row..dst_row + cw].copy_from_slice(&luma_bytes[src_row..src_row + cw]);
    }
    strip_border_artwork_luma(&mut crop, cw, ch);

    let threshold = ((cw as f64 * 0.02).round() as usize).max(2);
    let mut raw_rows: Vec<(usize, usize)> = Vec::new();
    let mut start_y: Option<usize> = None;

    for cy in 0..ch {
        let row = cy * cw;
        let dark = crop[row..row + cw].iter().filter(|&&v| v < 155).count();
        if dark >= threshold {
            if start_y.is_none() {
                start_y = Some(cy);
            }
        } else if let Some(sy) = start_y {
            if cy - sy >= 4 {
                raw_rows.push((sy, cy - 1));
            }
            start_y = None;
        }
    }
    if let Some(sy) = start_y {
        if ch - sy >= 4 {
            raw_rows.push((sy, ch - 1));
        }
    }

    if raw_rows.is_empty() {
        return vec![CleanedLineCrop {
            width: cw as u32,
            height: ch as u32,
            luma_bytes: crop,
        }];
    }

    let mut merged: Vec<(usize, usize)> = vec![raw_rows[0]];
    for &(sy, ey) in &raw_rows[1..] {
        let last = merged.last_mut().unwrap();
        if sy <= last.1 + 2 {
            last.1 = ey;
        } else {
            merged.push((sy, ey));
        }
    }

    merged
        .into_iter()
        .map(|(sy, ey)| {
            let ly0 = sy.saturating_sub(3);
            let ly1 = (ey + 4).min(ch);
            let lh = ly1 - ly0;
            let mut buf = vec![255u8; cw * lh];
            for r in 0..lh {
                let src_row = (ly0 + r) * cw;
                let dst_row = r * cw;
                buf[dst_row..dst_row + cw].copy_from_slice(&crop[src_row..src_row + cw]);
            }
            CleanedLineCrop {
                width: cw as u32,
                height: lh as u32,
                luma_bytes: buf,
            }
        })
        .collect()
}

/// 1채널 그레이스케일 버퍼를 PNG 바이트로 인코딩합니다 (디버깅 및 뷰어 오버레이 합성용).
#[flutter_rust_bridge::frb(sync)]
pub fn encode_luma_to_png(luma_bytes: Vec<u8>, width: u32, height: u32) -> Option<Vec<u8>> {
    let img = GrayImage::from_raw(width, height, luma_bytes)?;
    let mut out = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut out), ImageFormat::Png)
        .ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Luma, Rgb};

    #[test]
    fn test_preprocess_manga_grayscale_resize() {
        // 2000x1000 RGB 합성 이미지 -> max_long_edge=1280 -> 1280x640 그레이스케일
        let mut rgb: ImageBuffer<Rgb<u8>, Vec<u8>> = ImageBuffer::new(2000, 1000);
        for pixel in rgb.pixels_mut() {
            *pixel = Rgb([240, 240, 240]);
        }

        let mut png_bytes = Vec::new();
        rgb.write_to(&mut std::io::Cursor::new(&mut png_bytes), ImageFormat::Png)
            .unwrap();

        let res = preprocess_manga_grayscale(png_bytes, 1280).expect("preprocess should succeed");
        assert_eq!(res.orig_width, 2000);
        assert_eq!(res.orig_height, 1000);
        assert_eq!(res.width, 1280);
        assert_eq!(res.height, 640);
        assert_eq!(res.luma_bytes.len(), (1280 * 640) as usize);
    }

    #[test]
    fn test_filter_speech_bubbles_distinguishes_noise() {
        let w = 100u32;
        let h = 100u32;
        // 전체 어두운 배경(밝기 20)
        let mut luma = vec![20u8; (w * h) as usize];

        // (10, 10) ~ (40, 40) 영역에 흰색 말풍선(밝기 255) 생성
        for y in 10..40 {
            for x in 10..40 {
                luma[(y * w + x) as usize] = 255;
            }
        }

        let boxes = vec![
            // 말풍선 내부 텍스트 박스 (테두리 링이 흰색 영역에 포함)
            TextBoxInput {
                x: 15,
                y: 15,
                width: 20,
                height: 20,
            },
            // 어두운 배경 위 효과음 박스 (테두리 링이 어두움)
            TextBoxInput {
                x: 60,
                y: 60,
                width: 20,
                height: 20,
            },
        ];

        // allow_inverted=false로 일반 흰색 말풍선만 허용 테스트
        let filtered = filter_speech_bubbles(luma, w, h, boxes, 3, 0.75, false);
        assert_eq!(filtered.len(), 2);
        assert!(filtered[0].is_speech_bubble);
        assert!(!filtered[0].is_inverted);
        assert!(filtered[0].white_ratio > 0.99);

        assert!(!filtered[1].is_speech_bubble);
        assert!(filtered[1].white_ratio < 0.01);
    }

    #[test]
    fn test_zero_ai_erase_preserves_border_outline_and_erases_text() {
        let w = 40u32;
        let h = 40u32;
        let mut img: ImageBuffer<Luma<u8>, Vec<u8>> = ImageBuffer::from_pixel(w, h, Luma([255]));

        // 크롭 경계선(0, 39)에 닿는 말풍선 테두리 선화 (검정 0)
        for i in 0..40 {
            img.put_pixel(i, 0, Luma([0]));
            img.put_pixel(i, 39, Luma([0]));
            img.put_pixel(0, i, Luma([0]));
            img.put_pixel(39, i, Luma([0]));
        }

        // 내부에 고립된 글자 블록 (15..25, 15..25) (검정 0)
        for y in 15..25 {
            for x in 15..25 {
                img.put_pixel(x, y, Luma([0]));
            }
        }

        let res = erase_bubble_text_zero_ai(
            img.into_raw(),
            w,
            h,
            vec![BubbleEraseRegion {
                x: 0,
                y: 0,
                width: 40,
                height: 40,
                is_inverted: false,
            }],
            1,
        )
        .expect("erase should succeed");

        // 외곽 경계선(말풍선 테두리)은 그대로 검정(0)으로 보존되어야 함
        assert_eq!(res.luma_bytes[0], 0);
        assert_eq!(res.luma_bytes[20], 0);
        assert!(res.preserved_border_components >= 1);

        // 내부 고립 글자는 흰색(255)으로 지워져야 함
        assert_eq!(res.luma_bytes[(20 * w + 20) as usize], 255);
        assert!(res.erased_pixel_count >= 100);
    }

    #[test]
    fn test_benchmark_real_testimage_if_present() {
        let path = "../../translation_lab/testimage/japanese/01_original.png";
        let Ok(bytes) = std::fs::read(path) else {
            return;
        };

        let prep = preprocess_and_detect_bubbles_sync(bytes, 1280).expect("real testimage decode");
        let mid_box = BubbleEraseRegion {
            x: (prep.width / 4) as i32,
            y: (prep.height / 4) as i32,
            width: (prep.width / 6) as i32,
            height: (prep.height / 6) as i32,
            is_inverted: false,
        };
        let erased = erase_bubble_text_zero_ai(
            prep.luma_bytes,
            prep.width,
            prep.height,
            vec![mid_box],
            2,
        )
        .expect("zero-ai erase");

        println!(
            "[Benchmark] 01_original.png ({}x{} -> {}x{}): preprocess={:.2}ms, detect={:.2}ms (bubbles={}), zero_ai_erase={:.2}ms",
            prep.orig_width,
            prep.orig_height,
            prep.width,
            prep.height,
            prep.preprocess_ms,
            prep.detect_ms,
            prep.bubbles.len(),
            erased.latency_ms,
        );
        assert!(prep.bubbles.len() >= 3);
        assert!(erased.latency_ms < 50.0);
    }
}
