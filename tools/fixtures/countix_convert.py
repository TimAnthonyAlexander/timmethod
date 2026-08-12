#!/usr/bin/env python3
"""Countix -> fixtures/countix conversion (W1-06).

For each selected Countix row:
  1. yt-dlp the YouTube id, downloading only the [kinetics_start, kinetics_end]
     window (via --download-sections) instead of the whole video.
  2. Re-encode the trimmed segment to a constant-frame-rate .mov with ffmpeg
     (variable frame rate breaks frame-indexed ground truth downstream).
  3. Write a sidecar .json matching core/Sources/TimMethodCore/Fixtures/Fixture.swift,
     converting repetition_start/repetition_end (seconds in the ORIGINAL video)
     to clip-relative seconds and emitting them as the single trueSetBoundaries
     entry. No per-rep timestamps are invented -- Countix doesn't provide them.

This is tooling, not shipped code: run it by hand, point it at the Countix
CSVs, get a fixtures/countix/ directory and a JSON result log out of it.

Usage:
  python3 countix_convert.py \
      --train /path/countix_train.csv --val /path/countix_val.csv \
      --out-dir /path/to/repo/fixtures/countix \
      --classes "bench pressing,squat,pull ups,push up" \
      --max-attempts 260 --concurrency 10 \
      --results-out /path/to/results.json
"""
from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
import tempfile
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

# class -> (exerciseId, equipment, plateDiameterMm or None)
CLASS_MAP = {
    "bench pressing": ("bench_press", "barbell", 450),
    "squat": ("back_squat", "barbell", 450),  # Countix mixes barbell/bodyweight squats; see MANIFEST.
    "pull ups": ("pull_up", "bodyweight", None),
    "push up": ("push_up", "bodyweight", None),
    "exercising arm": ("arm_exercise", "dumbbell", None),
    "rope pushdown": ("rope_pushdown", "machine", None),
}

LICENCE = "unverifiedCommercialUse"
CAMERA_POSITION_DEFAULT = "frontal90"  # placeholder pending visual pass; see relabel_camera.py
SOURCE_DATASET = "Countix"


@dataclass
class Row:
    video_id: str
    cls: str
    kinetics_start: float
    kinetics_end: float
    repetition_start: float
    repetition_end: float
    count: int


def load_rows(csv_path: Path, wanted_classes: set[str]) -> list[Row]:
    rows: list[Row] = []
    with csv_path.open() as f:
        for r in csv.DictReader(f):
            if r["class"] not in wanted_classes:
                continue
            try:
                rows.append(Row(
                    video_id=r["video_id"],
                    cls=r["class"],
                    kinetics_start=float(r["kinetics_start"]),
                    kinetics_end=float(r["kinetics_end"]),
                    repetition_start=float(r["repetition_start"]),
                    repetition_end=float(r["repetition_end"]),
                    count=int(float(r["count"])),
                ))
            except (KeyError, ValueError):
                continue
    return rows


def interleave_by_class(rows: list[Row]) -> list[Row]:
    """Round-robins across classes so early attrition doesn't starve any one class."""
    buckets: dict[str, list[Row]] = {}
    for row in rows:
        buckets.setdefault(row.cls, []).append(row)
    order = list(buckets.keys())
    out: list[Row] = []
    i = 0
    while any(buckets.values()):
        cls = order[i % len(order)]
        if buckets[cls]:
            out.append(buckets[cls].pop(0))
        i += 1
    return out


@dataclass
class Result:
    video_id: str
    cls: str
    clip_id: str
    ok: bool
    reason: str = ""


def classify_ytdlp_error(stderr: str) -> str:
    s = stderr.lower()
    if "terminated" in s or "account" in s and "terminat" in s:
        return "account_terminated"
    if "private video" in s:
        return "private"
    if "unavailable" in s and "region" in s:
        return "region_blocked"
    if "not available" in s and "country" in s:
        return "region_blocked"
    if "video unavailable" in s:
        return "unavailable_or_deleted"
    if "sign in" in s or "age" in s:
        return "age_or_login_restricted"
    if "copyright" in s:
        return "copyright_takedown"
    if "timed out" in s or "timeout" in s:
        return "timeout"
    if "hd extractor" in s or "unsupported url" in s:
        return "extractor_error"
    return "other"


def process_row(row: Row, out_dir: Path, tmp_root: Path, fps: int) -> Result:
    exercise_id, equipment, plate_mm = CLASS_MAP[row.cls]
    clip_id = f"{row.video_id}_{int(row.kinetics_start)}_{int(row.kinetics_end)}"
    json_path = out_dir / f"{clip_id}.json"
    mov_path = out_dir / f"{clip_id}.mov"

    if json_path.exists() and mov_path.exists():
        return Result(row.video_id, row.cls, clip_id, True, "already_present")

    with tempfile.TemporaryDirectory(dir=tmp_root) as td:
        tmp = Path(td)
        raw_template = tmp / "raw.%(ext)s"
        section = f"*{row.kinetics_start:.0f}-{row.kinetics_end:.0f}"
        url = f"https://www.youtube.com/watch?v={row.video_id}"

        try:
            proc = subprocess.run(
                [
                    "yt-dlp",
                    "--download-sections", section,
                    "-f", "bv*[height<=480][ext=mp4]+ba[ext=m4a]/b[height<=480][ext=mp4]/bv*+ba/b",
                    "--force-keyframes-at-cuts",
                    "--socket-timeout", "20",
                    "--retries", "1",
                    "--fragment-retries", "1",
                    "--no-playlist",
                    "--no-warnings",
                    "-o", str(raw_template),
                    url,
                ],
                capture_output=True, text=True, timeout=90,
            )
        except subprocess.TimeoutExpired:
            return Result(row.video_id, row.cls, clip_id, False, "download_timeout")

        if proc.returncode != 0:
            reason = classify_ytdlp_error(proc.stderr)
            return Result(row.video_id, row.cls, clip_id, False, reason)

        raw_files = list(tmp.glob("raw.*"))
        if not raw_files:
            return Result(row.video_id, row.cls, clip_id, False, "no_output_file")
        raw_file = raw_files[0]

        out_dir.mkdir(parents=True, exist_ok=True)
        tmp_mov = tmp / "out.mov"
        try:
            proc2 = subprocess.run(
                [
                    "ffmpeg", "-y", "-i", str(raw_file),
                    "-r", str(fps), "-vsync", "cfr",
                    "-an",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart",
                    str(tmp_mov),
                ],
                capture_output=True, text=True, timeout=60,
            )
        except subprocess.TimeoutExpired:
            return Result(row.video_id, row.cls, clip_id, False, "ffmpeg_timeout")

        if proc2.returncode != 0 or not tmp_mov.exists():
            return Result(row.video_id, row.cls, clip_id, False, "ffmpeg_failed")

        # Probe actual duration of the encoded clip to clamp set-boundary times.
        try:
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", str(tmp_mov)],
                capture_output=True, text=True, timeout=20,
            )
            duration = float(probe.stdout.strip())
        except Exception:
            duration = row.kinetics_end - row.kinetics_start

        if duration <= 0:
            return Result(row.video_id, row.cls, clip_id, False, "empty_output")

        shutil.move(str(tmp_mov), str(mov_path))

    # Sidecar. repetition_start/end are ORIGINAL-video-relative seconds;
    # convert to clip-relative by subtracting kinetics_start.
    rep_start = max(0.0, row.repetition_start - row.kinetics_start)
    rep_end = min(duration, row.repetition_end - row.kinetics_start)
    if rep_end <= rep_start:
        # Degenerate after clamping (rare edge float case) -- drop the boundary
        # rather than emit an invalid one; loader rejects endTime <= startTime.
        set_boundaries = None
    else:
        set_boundaries = [{"startTime": round(rep_start, 3), "endTime": round(rep_end, 3)}]

    fixture = {
        "exerciseId": exercise_id,
        "equipment": equipment,
        "plateDiameterMm": plate_mm,
        "trueRepCount": row.count,
        "truePartialCount": 0,
        "cameraPosition": CAMERA_POSITION_DEFAULT,
        "lightingNote": "found footage (YouTube, via Countix/Kinetics) -- not visually assessed at conversion time",
        "sourceDataset": SOURCE_DATASET,
        "licence": LICENCE,
        "perRepTimestamps": None,
        "referenceMeanConcentricVelocity": None,
        "trueSetBoundaries": set_boundaries,
    }
    json_path.write_text(json.dumps(fixture, indent=2) + "\n")

    return Result(row.video_id, row.cls, clip_id, True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", type=Path, required=True)
    ap.add_argument("--val", type=Path, required=True)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--classes", type=str, required=True, help="comma-separated Countix class names")
    ap.add_argument("--max-attempts", type=int, default=260)
    ap.add_argument("--target-resolved", type=int, default=200, help="stop early once this many resolve")
    ap.add_argument("--concurrency", type=int, default=10)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--results-out", type=Path, required=True)
    ap.add_argument("--tmp-root", type=Path, default=Path(tempfile.gettempdir()))
    args = ap.parse_args()

    wanted = {c.strip() for c in args.classes.split(",")}
    rows = load_rows(args.train, wanted) + load_rows(args.val, wanted)
    rows = interleave_by_class(rows)
    rows = rows[: args.max_attempts]

    print(f"attempting up to {len(rows)} rows across classes: {sorted(wanted)}", file=sys.stderr)

    results: list[Result] = []
    resolved = 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futures = {ex.submit(process_row, row, args.out_dir, args.tmp_root, args.fps): row for row in rows}
        for fut in as_completed(futures):
            row = futures[fut]
            try:
                res = fut.result()
            except Exception as e:  # keep going past any per-row crash
                res = Result(row.video_id, row.cls, "", False, f"exception:{e}")
            results.append(res)
            status = "OK" if res.ok else f"FAIL({res.reason})"
            print(f"[{len(results)}/{len(rows)}] {row.cls:16s} {row.video_id} {status}", file=sys.stderr)
            if res.ok:
                resolved += 1
                if resolved >= args.target_resolved:
                    print(f"reached target of {args.target_resolved} resolved clips; not cancelling in-flight but stopping new submissions is not supported by this pool -- letting remaining in-flight finish", file=sys.stderr)

    by_class: dict[str, dict[str, int]] = {}
    for r in results:
        b = by_class.setdefault(r.cls, {"attempted": 0, "resolved": 0})
        b["attempted"] += 1
        if r.ok:
            b["resolved"] += 1

    fail_reasons: dict[str, int] = {}
    for r in results:
        if not r.ok:
            fail_reasons[r.reason] = fail_reasons.get(r.reason, 0) + 1

    summary = {
        "attempted": len(results),
        "resolved": sum(1 for r in results if r.ok),
        "by_class": by_class,
        "fail_reasons": fail_reasons,
        "results": [r.__dict__ for r in results],
    }
    args.results_out.write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != "results"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
