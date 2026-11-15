#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
monitor_dialogue_records.py
원작자(project-violet/fscm-dist, project-violet/violet)의 대사 레코드(FSCM) 및
대사 검색 모듈의 업데이트를 감지하여 Discord notice 채널로 알림을 전송하는 스크립트입니다.
"""

import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_WEBHOOK_URL = (
    "https://discord.com/api/webhooks/1547865928145043456/"
    "DH286fi0zHhokOAYWAtZasQT0dUFPRPapPGbF8GhhMevK0TKIKpCF0WHIa3chPJD5glz"
)

DEFAULT_STATE_FILE = os.path.join(".github", "state", "fscm_monitor_state.json")

GITHUB_API_BASE = "https://api.github.com"


def fetch_github_json(endpoint: str, token: str | None = None):
    url = f"{GITHUB_API_BASE}/{endpoint.lstrip('/')}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "VioletLite-Dialogue-Monitor",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="ignore")
        print(f"[!] GitHub API HTTP {e.code} error for {endpoint}: {error_body}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[!] Error fetching {endpoint}: {e}", file=sys.stderr)
        return None


def collect_current_state(token: str | None = None) -> dict:
    state = {
        "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "fscm_dist_releases": [],
        "fscm_dist_latest_commit": None,
        "violet_message_search_latest_commit": None,
    }

    # 1. fscm-dist releases
    releases_data = fetch_github_json("repos/project-violet/fscm-dist/releases", token)
    if isinstance(releases_data, list):
        releases_summary = []
        for rel in releases_data:
            assets_summary = []
            for asset in rel.get("assets", []):
                assets_summary.append({
                    "name": asset.get("name"),
                    "size": asset.get("size"),
                    "updated_at": asset.get("updated_at"),
                    "download_url": asset.get("browser_download_url"),
                })
            releases_summary.append({
                "id": rel.get("id"),
                "tag_name": rel.get("tag_name"),
                "name": rel.get("name"),
                "published_at": rel.get("published_at"),
                "html_url": rel.get("html_url"),
                "assets": assets_summary,
            })
        state["fscm_dist_releases"] = releases_summary

    # 2. fscm-dist latest commit
    fscm_commits = fetch_github_json("repos/project-violet/fscm-dist/commits?per_page=1", token)
    if isinstance(fscm_commits, list) and len(fscm_commits) > 0:
        c = fscm_commits[0]
        state["fscm_dist_latest_commit"] = {
            "sha": c.get("sha"),
            "date": c.get("commit", {}).get("committer", {}).get("date"),
            "message": c.get("commit", {}).get("message", "").splitlines()[0],
            "html_url": c.get("html_url"),
        }

    # 3. project-violet/violet message-search latest commit
    violet_commits = fetch_github_json(
        "repos/project-violet/violet/commits?path=violet-message-search&per_page=1", token
    )
    if isinstance(violet_commits, list) and len(violet_commits) > 0:
        vc = violet_commits[0]
        state["violet_message_search_latest_commit"] = {
            "sha": vc.get("sha"),
            "date": vc.get("commit", {}).get("committer", {}).get("date"),
            "message": vc.get("commit", {}).get("message", "").splitlines()[0],
            "html_url": vc.get("html_url"),
        }

    return state


def compare_states(old_state: dict, new_state: dict) -> list[str]:
    diffs = []

    # 1. fscm-dist 릴리스 비교
    old_releases = {r["tag_name"]: r for r in old_state.get("fscm_dist_releases", [])}
    new_releases = {r["tag_name"]: r for r in new_state.get("fscm_dist_releases", [])}

    for tag, n_rel in new_releases.items():
        if tag not in old_releases:
            diffs.append(f"🎉 **fscm-dist 신규 릴리스 발행**: `{tag}` ({n_rel.get('name')})")
        else:
            o_rel = old_releases[tag]
            # 에셋 비교
            o_assets = {a["name"]: a for a in o_rel.get("assets", [])}
            n_assets = {a["name"]: a for a in n_rel.get("assets", [])}

            for a_name, n_a in n_assets.items():
                if a_name not in o_assets:
                    size_mb = n_a.get("size", 0) / (1024 * 1024)
                    diffs.append(f"📦 **fscm-dist 새 에셋 추가**: `{tag}`의 `{a_name}` ({size_mb:.1f} MB)")
                else:
                    o_a = o_assets[a_name]
                    if o_a.get("size") != n_a.get("size") or o_a.get("updated_at") != n_a.get("updated_at"):
                        o_mb = o_a.get("size", 0) / (1024 * 1024)
                        n_mb = n_a.get("size", 0) / (1024 * 1024)
                        diffs.append(
                            f"🔄 **fscm-dist 에셋 갱신**: `{tag}`의 `{a_name}` ({o_mb:.1f} MB ➔ {n_mb:.1f} MB)"
                        )

    # 2. fscm-dist 커밋 비교
    old_fc = old_state.get("fscm_dist_latest_commit") or {}
    new_fc = new_state.get("fscm_dist_latest_commit") or {}
    if new_fc.get("sha") and old_fc.get("sha") and new_fc.get("sha") != old_fc.get("sha"):
        diffs.append(
            f"📝 **fscm-dist 저장소 신규 커밋**: [`{new_fc.get('sha')[:7]}`]({new_fc.get('html_url')}) {new_fc.get('message')}"
        )

    # 3. violet-message-search 커밋 비교
    old_vc = old_state.get("violet_message_search_latest_commit") or {}
    new_vc = new_state.get("violet_message_search_latest_commit") or {}
    if new_vc.get("sha") and old_vc.get("sha") and new_vc.get("sha") != old_vc.get("sha"):
        diffs.append(
            f"⚙️ **violet-message-search 모듈 신규 커밋**: [`{new_vc.get('sha')[:7]}`]({new_vc.get('html_url')}) {new_vc.get('message')}"
        )

    return diffs


def send_discord_notification(webhook_url: str, diffs: list[str], state: dict, is_test: bool = False):
    now_kst = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime(
        "%Y-%m-%d %H:%M:%S KST"
    )

    fscm_rel = state.get("fscm_dist_releases", [{}])[0] if state.get("fscm_dist_releases") else {}
    fscm_tag = fscm_rel.get("tag_name", "N/A")
    fscm_url = fscm_rel.get("html_url", "https://github.com/project-violet/fscm-dist/releases")

    violet_c = state.get("violet_message_search_latest_commit") or {}
    violet_sha = violet_c.get("sha", "")[:7] or "N/A"
    violet_msg = violet_c.get("message", "N/A")
    violet_url = violet_c.get("html_url", "https://github.com/project-violet/violet")

    title_prefix = "🧪 [테스트] " if is_test else "📢 "
    title = f"{title_prefix}원작자 대사 레코드(FSCM) 업데이트 감지"

    diff_text = "\n".join(diffs) if diffs else "감지된 신규 변경 사항이 없습니다 (테스트 점검)."
    if len(diff_text) > 1000:
        diff_text = diff_text[:990] + "\n...(생략)"

    embed = {
        "title": title,
        "color": 0x7B1FA2,  # Violet Deep Purple
        "description": "원작자 저장소(`project-violet`)에서 대사 코퍼스 또는 검색 모듈의 변경이 감지되었습니다.",
        "fields": [
            {
                "name": "🔔 감지된 변경 내역",
                "value": diff_text,
                "inline": False,
            },
            {
                "name": "📦 fscm-dist 최신 릴리스",
                "value": f"[{fscm_tag}]({fscm_url})",
                "inline": True,
            },
            {
                "name": "⚙️ message-search 최신 커밋",
                "value": f"[{violet_sha}]({violet_url}) `{violet_msg}`",
                "inline": True,
            },
            {
                "name": "🛠️ 권장 후속 조치",
                "value": (
                    "1. `python tools/extract_korean_fscm.py --input <merged-0.fscm>` 실행\n"
                    "2. 생성된 `merged-ko.fscm.7z`를 `database` 릴리스에 갱신 업로드\n"
                    "3. 앱 사용자 대상 최신 한국어 대사 검색 인덱스 자동 배포 완료"
                ),
                "inline": False,
            },
        ],
        "footer": {
            "text": f"Violet Lite Automation • 감지 시각: {now_kst}",
        },
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }

    payload = {
        "username": "Violet Dialogue Monitor",
        "avatar_url": "https://raw.githubusercontent.com/project-violet/violet/dev/assets/images/logo.png",
        "embeds": [embed],
    }

    req_data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=req_data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "VioletLite-Dialogue-Monitor",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            if res.status in (200, 204):
                print(f"[+] Discord notice notification sent successfully! (HTTP {res.status})")
                return True
            else:
                print(f"[!] Discord returned unexpected status: {res.status}", file=sys.stderr)
                return False
    except Exception as e:
        print(f"[!] Failed to send Discord notification: {e}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description="Monitor Project Violet dialogue records (FSCM)")
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help="Path to state json file")
    parser.add_argument("--webhook", default=None, help="Discord Webhook URL override")
    parser.add_argument("--token", default=None, help="GitHub API Token for rate limit extension")
    parser.add_argument("--force", action="store_true", help="Force send Discord alert even without diffs")
    parser.add_argument("--dry-run", action="store_true", help="Do not save state and do not send alert")
    args = parser.parse_args()

    token = args.token or os.environ.get("GITHUB_TOKEN")
    webhook_url = args.webhook or os.environ.get("DISCORD_WEBHOOK_URL") or DEFAULT_WEBHOOK_URL

    print("[*] Fetching current state from GitHub API...")
    current_state = collect_current_state(token)

    # 이전 상태 로드
    old_state = {}
    if os.path.exists(args.state_file):
        try:
            with open(args.state_file, "r", encoding="utf-8") as f:
                old_state = json.load(f)
            print(f"[*] Loaded existing state from {args.state_file}")
        except Exception as e:
            print(f"[!] Warning: failed to parse existing state file: {e}")
    else:
        print(f"[*] No existing state file found at {args.state_file}. First run detected.")

    diffs = compare_states(old_state, current_state) if old_state else []

    if diffs:
        print(f"[+] Detected {len(diffs)} difference(s):")
        for d in diffs:
            print(f"    - {d}")
    else:
        print("[*] No updates detected in upstream dialogue records.")

    should_notify = bool(diffs) or args.force
    if should_notify and not args.dry_run:
        print("[*] Sending Discord notification...")
        send_discord_notification(webhook_url, diffs, current_state, is_test=(args.force and not diffs))
    elif args.dry_run:
        print("[*] Dry-run mode: skipped sending notification.")

    # 상태 저장
    if not args.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(args.state_file)), exist_ok=True)
        with open(args.state_file, "w", encoding="utf-8") as f:
            json.dump(current_state, f, indent=2, ensure_ascii=False)
        print(f"[+] State successfully saved to {args.state_file}")

    # GitHub Actions output 설정
    has_update = "true" if bool(diffs) else "false"
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output and os.path.exists(github_output):
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"has_update={has_update}\n")
            f.write(f"diff_count={len(diffs)}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
