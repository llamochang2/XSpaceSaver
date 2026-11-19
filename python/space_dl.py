#!/usr/bin/env python3
"""X Space 다시듣기 음성을 master_playlist.m3u8 URL로 받아 m4a 파일로 저장.

플레이리스트가 가리키는 조각 경로가 실제 위치와 다른 경우(transcode 경로 400 등)
master URL 폴더 등 후보 경로를 확인해서 자동 보정함.

사용법:
    python space_dl.py "<master_playlist.m3u8 URL>" [-o 파일명.m4a] [--workers 8] [--keep]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from urllib.error import HTTPError
from urllib.parse import urljoin
from urllib.request import Request, urlopen

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
    ),
    "Referer": "https://x.com/",
}
SEGMENT_TAGS = ("#EXTINF", "#EXT-X-PROGRAM-DATE-TIME", "#EXT-X-DISCONTINUITY")


# ---------- HTTP ----------

def fetch(url, timeout=30):
    with urlopen(Request(url, headers=HEADERS), timeout=timeout) as r:
        return r.read()


def fetch_text(url):
    return fetch(url).decode("utf-8", "replace")


def status_of(url):
    """URL 응답 코드만 확인. 네트워크 오류면 None."""
    try:
        with urlopen(Request(url, headers=HEADERS), timeout=20) as r:
            r.read(1)
            return r.status
    except HTTPError as e:
        return e.code
    except OSError:
        return None


# ---------- 플레이리스트 처리 ----------

def uri_lines(text):
    return [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]


def dir_of(url):
    return url.split("?", 1)[0].rsplit("/", 1)[0] + "/"


def without_b(url):
    return url.replace("/b/Transcoding/", "/Transcoding/")


def load_media_playlist(master_url):
    """master playlist면 첫 번째 variant를 따라가서 (playlist URL, 내용) 반환."""
    text = fetch_text(master_url)
    if "#EXT-X-STREAM-INF" not in text:
        return master_url, text

    variants = uri_lines(text)
    if not variants:
        raise RuntimeError("master playlist에 variant 항목 없음")

    url = urljoin(master_url, variants[0])
    last_err = None
    for cand in dict.fromkeys([url, without_b(url)]):
        try:
            return cand, fetch_text(cand)
        except OSError as e:
            last_err = e
    raise RuntimeError(f"variant playlist 로드 실패: {last_err}")


def parse_segments(text):
    """(헤더 태그, [(세그먼트 태그 목록, URI)], 꼬리 태그) 로 분리."""
    header, segments, pending = [], [], []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            if segments or pending or line.startswith(SEGMENT_TAGS):
                pending.append(line)
            else:
                header.append(line)
        else:
            segments.append((pending, line))
            pending = []
    return header, segments, pending


def find_chunk_base(master_url, playlist_url, first_uri):
    """첫 조각이 실제로 받아지는 기준 경로 탐색."""
    candidates = []
    for base in (dir_of(playlist_url), dir_of(master_url)):
        candidates += [base, without_b(base)]

    for base in dict.fromkeys(candidates):
        url = urljoin(base, first_uri)
        code = status_of(url)
        print(f"  경로 확인 {code}: {base}")
        if code == 200:
            return base
    raise RuntimeError("조각 파일 경로를 찾지 못함 (녹음 삭제 또는 비공개 전환 가능성)")


# ---------- 다운로드 ----------

def download(url, path, retries=5):
    for attempt in range(retries):
        try:
            data = fetch(url)
            with open(path, "wb") as f:
                f.write(data)
            return
        except HTTPError as e:
            if e.code in (403, 404) or attempt == retries - 1:
                raise
        except OSError:
            if attempt == retries - 1:
                raise
        time.sleep(1.5 * (attempt + 1))


def download_all(base, segments, work_dir, workers):
    """조각 병렬 다운로드. 실패한 인덱스 집합 반환."""
    total = len(segments)
    failed, done = set(), 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(download, urljoin(base, uri), os.path.join(work_dir, f"{i:06d}.aac")): i
            for i, (_, uri) in enumerate(segments)
        }
        for fut in as_completed(futures):
            i = futures[fut]
            try:
                fut.result()
            except Exception as e:  # noqa: BLE001 - 개별 조각 실패는 건너뜀
                failed.add(i)
                print(f"\n  조각 {i} 실패, 건너뜀: {e}")
            done += 1
            print(f"\r  다운로드 {done}/{total}", end="", flush=True)
    print()
    return failed


def write_local_playlist(path, header, segments, tail, failed):
    lines = list(header)
    for i, (tags, _) in enumerate(segments):
        if i in failed:
            continue
        lines += tags
        lines.append(f"{i:06d}.aac")
    lines += tail
    if "#EXT-X-ENDLIST" not in lines:
        lines.append("#EXT-X-ENDLIST")
    with open(path, "w", encoding="ascii") as f:
        f.write("\n".join(lines) + "\n")


# ---------- ffmpeg ----------

def run_ffmpeg(playlist_path, out_path):
    base = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-allowed_extensions", "ALL"]
    tail = ["-i", playlist_path, "-c", "copy", out_path]
    # -extension_picky 는 ffmpeg 7.1 이상만 지원 -> 실패 시 옵션 빼고 재시도
    r = subprocess.run(base + ["-extension_picky", "0"] + tail, capture_output=True, text=True)
    if r.returncode != 0 and "extension_picky" in (r.stderr or ""):
        r = subprocess.run(base + tail, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr)
    return r.returncode


def unique_path(path):
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(path)
    n = 1
    while os.path.exists(f"{stem}_{n}{ext}"):
        n += 1
    return f"{stem}_{n}{ext}"


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser(description="X Space master URL -> m4a 저장")
    ap.add_argument("url", nargs="?", help="master_playlist.m3u8 URL")
    ap.add_argument("-o", "--output", help="저장 파일명 (기본: space_날짜_시간.m4a)")
    ap.add_argument("--workers", type=int, default=8, help="동시 다운로드 수 (기본 8)")
    ap.add_argument("--keep", action="store_true", help="임시 조각 폴더 유지")
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg 없음. 설치 후 터미널 재시작 필요 (winget install --id Gyan.FFmpeg -e)")

    master_url = (args.url or input("master URL: ")).strip().strip('"')
    out_path = unique_path(args.output or datetime.now().strftime("space_%Y%m%d_%H%M%S.m4a"))

    print("[1/4] 플레이리스트 확인")
    playlist_url, text = load_media_playlist(master_url)
    header, segments, tail = parse_segments(text)
    if not segments:
        sys.exit("조각 목록이 비어 있음 (진행 중인 Space이거나 녹음 없음)")
    seconds = sum(
        float(t.split(":", 1)[1].rstrip(",")) for tags, _ in segments for t in tags if t.startswith("#EXTINF")
    )
    print(f"  조각 {len(segments)}개, 약 {int(seconds // 60)}분 {int(seconds % 60)}초")

    print("[2/4] 조각 경로 탐색")
    base = find_chunk_base(master_url, playlist_url, segments[0][1])

    work_dir = tempfile.mkdtemp(prefix="space_")
    try:
        print("[3/4] 조각 다운로드")
        failed = download_all(base, segments, work_dir, args.workers)
        if len(failed) == len(segments):
            sys.exit("모든 조각 다운로드 실패")

        print("[4/4] m4a로 합치기")
        local_pl = os.path.join(work_dir, "local.m3u8")
        write_local_playlist(local_pl, header, segments, tail, failed)
        if run_ffmpeg(local_pl, os.path.abspath(out_path)) != 0:
            sys.exit(f"ffmpeg 실패. 조각 폴더 유지: {work_dir}")
    finally:
        if args.keep:
            print(f"  조각 폴더: {work_dir}")
        elif os.path.exists(os.path.abspath(out_path)):
            shutil.rmtree(work_dir, ignore_errors=True)

    print(f"완료: {os.path.abspath(out_path)}")
    if failed:
        print(f"  누락된 조각 {len(failed)}개 (해당 구간 끊김)")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\n중단됨")
    except RuntimeError as e:
        sys.exit(f"오류: {e}")
