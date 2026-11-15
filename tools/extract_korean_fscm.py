#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_korean_fscm.py
원작자 전체 대사 코퍼스(merged-0.fscm)와 SQLite DB(data.db) 또는 Hitomi 한국어 Nozomi 인덱스를 대조하여,
한국어 작품의 대사 레코드만 스트리밍 추출해 `merged-ko.fscm` 및 배포용 단일 `merged-ko.fscm.7z`(~30~50MB)를 생성합니다.
"""

import argparse
import mmap
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import time
import urllib.request

FLAT_MAGIC = b"FSCMMSG1"
FLAT_VERSION = 1
FLAT_FLAG_RAW = 1
HEADER_LEN = 32
RECORD_LEN = 52
RECORD_STRUCT = struct.Struct("<IIQIQIf4f")

FLAT_V2_MAGIC = b"FSCMMSG2"
FLAT_V2_VERSION = 2
V2_BLOCK_RECORDS = 16384
V2_ARTICLE_STRUCT = struct.Struct("<III")
V2_BLOCK_STRUCT = struct.Struct("<IIIIQIIQII")
V2_PENDING_STRUCT = struct.Struct("<IHBQHHHHH")  # aid, page, corr_u8, msg_off, msg_len, x1, y1, w, h (29B)

if sys.stdout.encoding != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def load_korean_ids_from_db(db_path: str) -> set[int]:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("SELECT Id FROM HitomiColumnModel WHERE Language = 'korean'")
    ids = {int(row[0]) for row in cur.fetchall() if row[0] is not None}
    conn.close()
    return ids


def fetch_korean_ids_from_nozomi() -> set[int]:
    url = "https://ltn.gold-usergeneratedcontent.net/index-korean.nozomi"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            "Referer": "https://hitomi.la/",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as res:
        data = res.read()
    count = len(data) // 4
    return {struct.unpack(">I", data[i * 4 : (i + 1) * 4])[0] for i in range(count)}


def _is_meaningful_message(msg: bytes) -> bool:
    if len(msg) < 2:
        return False
    for b in msg:
        if (65 <= b <= 90) or (97 <= b <= 122) or (48 <= b <= 57) or b >= 128:
            return True
    return False


def _clamp_u16(val: float) -> int:
    iv = int(round(val))
    if iv < 0:
        return 0
    if iv > 65535:
        return 65535
    return iv


def extract_korean_fscm(
    src_fscm: str,
    dst_fscm: str,
    korean_ids: set[int],
    drop_raw: bool = False,
    prune_noise: bool = True,
) -> tuple[int, int]:
    start_t = time.time()
    with open(src_fscm, "rb") as f_in:
        header = f_in.read(HEADER_LEN)
        if len(header) != HEADER_LEN:
            raise ValueError("Invalid FSCM header length")
        magic, version, _flags, total_count, arena_bytes = struct.unpack("<8sIIQQ", header)
        if magic != FLAT_MAGIC or version != FLAT_VERSION:
            raise ValueError(f"Unsupported FSCM header: magic={magic}, version={version}")

        text_start = HEADER_LEN + total_count * RECORD_LEN
        print(f"[*] Source records: {total_count:,}, arena: {arena_bytes / 1024 / 1024:.1f} MiB")

        mm = mmap.mmap(f_in.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            rec_mv = memoryview(mm)[HEADER_LEN:text_start]
            arena_mv = memoryview(mm)[text_start : text_start + arena_bytes]

            # Stream-filter into compact in-memory buffers or temp chunks grouped by aid
            # Since source is 99.998% sorted by aid, keep a lightweight index list (aid, page, idx)
            # and store text in a single bytearray.
            pending_meta = bytearray()
            pending_text = bytearray()
            seen_per_page: dict[tuple[int, int], set[bytes]] = {}
            dropped_noise = 0
            dropped_dup = 0
            kept = 0
            pack_pending = V2_PENDING_STRUCT.pack

            for aid, page, m_off, m_len, _r_off, _r_len, corr, rx1, ry1, rx2, ry2 in RECORD_STRUCT.iter_unpack(rec_mv):
                if aid not in korean_ids:
                    continue
                msg = bytes(arena_mv[m_off : m_off + m_len])
                if prune_noise and not _is_meaningful_message(msg):
                    dropped_noise += 1
                    continue
                if prune_noise:
                    key = (aid, page)
                    bucket = seen_per_page.get(key)
                    if bucket is None:
                        if len(seen_per_page) > 4096:
                            seen_per_page.clear()
                        seen_per_page[key] = {msg}
                    elif msg in bucket:
                        dropped_dup += 1
                        continue
                    else:
                        bucket.add(msg)

                if len(msg) > 65535:
                    msg = msg[:65535]
                p_u16 = 65535 if page > 65535 else page
                c_u8 = int(round(min(max(corr, 0.0), 1.0) * 255.0))
                x1 = _clamp_u16(rx1)
                y1 = _clamp_u16(ry1)
                x2 = _clamp_u16(rx2)
                y2 = _clamp_u16(ry2)
                w = max(0, x2 - x1)
                h = max(0, y2 - y1)

                t_off = len(pending_text)
                pending_text.extend(msg)
                pending_meta.extend(pack_pending(aid, p_u16, c_u8, t_off, len(msg), x1, y1, w, h))
                kept += 1

            rec_mv.release()
            arena_mv.release()
        finally:
            mm.close()

    print(
        f"[+] Kept {kept:,} records "
        f"(pruned noise={dropped_noise:,}, dup={dropped_dup:,}). Sorting..."
    )
    sort_keys = [
        (((aid << 16) | p_u16) << 28) | idx
        for idx, (aid, p_u16, *_rest) in enumerate(V2_PENDING_STRUCT.iter_unpack(pending_meta))
    ]
    sort_keys.sort()

    unpack_from = V2_PENDING_STRUCT.unpack_from
    rec_stride = V2_PENDING_STRUCT.size
    mask_28 = (1 << 28) - 1

    articles: list[tuple[int, int, int]] = []
    for out_idx, sk in enumerate(sort_keys):
        aid = sk >> 44
        if articles and articles[-1][0] == aid:
            prev_aid, s_rec, cnt_r = articles[-1]
            articles[-1] = (prev_aid, s_rec, cnt_r + 1)
        else:
            articles.append((aid, out_idx, 1))

    block_count = (kept + V2_BLOCK_RECORDS - 1) // V2_BLOCK_RECORDS if kept else 0
    os.makedirs(os.path.dirname(os.path.abspath(dst_fscm)), exist_ok=True)
    tmp_hot_path = dst_fscm + ".hot.tmp"
    tmp_cold_path = dst_fscm + ".cold.tmp"
    block_entries = []
    text_mv = memoryview(pending_text)

    with (
        open(tmp_hot_path, "wb", buffering=4 * 1024 * 1024) as f_hot,
        open(tmp_cold_path, "wb", buffering=4 * 1024 * 1024) as f_cold,
    ):
        hot_cursor = 0
        cold_cursor = 0
        for b_idx in range(block_count):
            start = b_idx * V2_BLOCK_RECORDS
            end = min(start + V2_BLOCK_RECORDS, kept)
            n = end - start

            runs: list[tuple[int, int]] = []
            pages = bytearray(n * 2)
            corrects = bytearray(n)
            lens = bytearray(n * 2)
            x1s = bytearray(n * 2)
            y1s = bytearray(n * 2)
            ws = bytearray(n * 2)
            hs = bytearray(n * 2)
            text_chunks = bytearray()
            first_aid = 0
            last_aid = 0

            for local_i, sk in enumerate(sort_keys[start:end]):
                orig_idx = sk & mask_28
                aid, p_u16, c_u8, t_off, t_len, x1, y1, w, h = unpack_from(
                    pending_meta, orig_idx * rec_stride
                )
                if local_i == 0:
                    first_aid = aid
                last_aid = aid
                if runs and runs[-1][0] == aid:
                    runs[-1] = (aid, runs[-1][1] + 1)
                else:
                    runs.append((aid, 1))
                struct.pack_into("<H", pages, local_i * 2, p_u16)
                corrects[local_i] = c_u8
                struct.pack_into("<H", lens, local_i * 2, t_len)
                struct.pack_into("<H", x1s, local_i * 2, x1)
                struct.pack_into("<H", y1s, local_i * 2, y1)
                struct.pack_into("<H", ws, local_i * 2, w)
                struct.pack_into("<H", hs, local_i * 2, h)
                text_chunks.extend(text_mv[t_off : t_off + t_len])

            hot_header = bytearray(4 + len(runs) * 8)
            struct.pack_into("<I", hot_header, 0, len(runs))
            for r_i, (aid, cnt) in enumerate(runs):
                struct.pack_into("<II", hot_header, 4 + r_i * 8, aid, cnt)

            hot_len = len(hot_header) + len(pages) + len(corrects) + len(lens) + len(text_chunks)
            cold_len = n * 8
            f_hot.write(hot_header)
            f_hot.write(pages)
            f_hot.write(corrects)
            f_hot.write(lens)
            f_hot.write(text_chunks)

            f_cold.write(x1s)
            f_cold.write(y1s)
            f_cold.write(ws)
            f_cold.write(hs)

            block_entries.append(
                (first_aid, last_aid, start, n, hot_cursor, hot_len, hot_len, cold_cursor, cold_len, cold_len)
            )
            hot_cursor += hot_len
            cold_cursor += cold_len

    text_mv.release()
    del pending_meta, pending_text, sort_keys

    dir_start = 32 + len(articles) * 12 + len(block_entries) * 48
    hot_base = dir_start
    cold_base = dir_start + hot_cursor

    with open(dst_fscm, "wb", buffering=4 * 1024 * 1024) as f_out:
        f_out.write(
            struct.pack("<8sIIQII", FLAT_V2_MAGIC, FLAT_V2_VERSION, 0, kept, len(block_entries), len(articles))
        )
        for aid, s_rec, cnt in articles:
            f_out.write(V2_ARTICLE_STRUCT.pack(aid, s_rec, cnt))
        for fa, la, fr, rc, ho, hl, hrl, co, cl, crl in block_entries:
            f_out.write(
                V2_BLOCK_STRUCT.pack(fa, la, fr, rc, hot_base + ho, hl, hrl, cold_base + co, cl, crl)
            )
        with open(tmp_hot_path, "rb") as f_h:
            shutil.copyfileobj(f_h, f_out, length=4 * 1024 * 1024)
        with open(tmp_cold_path, "rb") as f_c:
            shutil.copyfileobj(f_c, f_out, length=4 * 1024 * 1024)

    os.remove(tmp_hot_path)
    os.remove(tmp_cold_path)
    out_size = os.path.getsize(dst_fscm)
    print(f"[+] Wrote V2 {dst_fscm} ({out_size / 1024 / 1024:.2f} MiB, {time.time() - start_t:.1f}s)")
    return kept, out_size


def compress_to_7z(src_fscm: str, dst_7z: str) -> None:
    if os.path.exists(dst_7z):
        os.remove(dst_7z)
    seven_zip = shutil.which("7z") or shutil.which("7za") or shutil.which("7zr")
    if seven_zip:
        subprocess.run([seven_zip, "a", "-t7z", "-mx=5", "-mmt=on", dst_7z, src_fscm], check=True)
        print(f"[+] Packaged {dst_7z} ({os.path.getsize(dst_7z) / 1024 / 1024:.2f} MiB)")
        return
    try:
        import py7zr  # type: ignore

        with py7zr.SevenZipFile(dst_7z, "w") as archive:
            archive.write(src_fscm, arcname=os.path.basename(src_fscm))
        print(f"[+] Packaged via py7zr: {dst_7z} ({os.path.getsize(dst_7z) / 1024 / 1024:.2f} MiB)")
    except ImportError:
        print("[!] Neither 7z/7za/7zr nor py7zr found. Please compress manually.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract Korean-only FSCM dialogue corpus")
    parser.add_argument("--input", required=True, help="Source merged-0.fscm path")
    parser.add_argument("--output", default="merged-ko.fscm", help="Output Korean .fscm path")
    parser.add_argument("--db", help="Optional SQLite data.db path")
    parser.add_argument("--with-nozomi", action="store_true", help="Merge Hitomi index-korean.nozomi IDs")
    parser.add_argument("--drop-raw", action="store_true", help="Drop stored raw text (app restores from 2-set)")
    parser.add_argument("--no-7z", action="store_true", help="Skip .7z compression")
    args = parser.parse_args()

    korean_ids: set[int] = set()
    if args.db:
        korean_ids |= load_korean_ids_from_db(args.db)
    if args.with_nozomi or not korean_ids:
        korean_ids |= fetch_korean_ids_from_nozomi()
    print(f"[*] Target Korean work IDs: {len(korean_ids):,}")

    extract_korean_fscm(args.input, args.output, korean_ids, drop_raw=args.drop_raw)
    if not args.no_7z:
        compress_to_7z(args.output, args.output + ".7z")


if __name__ == "__main__":
    main()
