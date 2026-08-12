# Fixture corpus manifest (W1-06)

Record of what's in `fixtures/`, where it came from, and what it may be used
for. See `fixtures/README.md` for the sidecar schema itself.

## Sources tried

| Source | Outcome | Clips |
|---|---|---|
| Countix (train+val, `bench pressing`/`squat`/`pull ups`/`push up`) | **Resolved** | see below |
| Countix (train+val, `exercising arm`, optional per the task) | **Resolved, partial** | see below |
| RepCount-A | **Blocked** — not ungated in practice | 0 |
| MM-Fit | **Downloaded, unusable** — no video in the distribution | 0 |
| InfiniteRep | **Downloaded, unusable** — no video, no counts, wrong licence | 0 |

## Countix

**What it is.** 8,375 YouTube clips derived from Kinetics-700, each with a
`class`, a `count`, and `repetition_start`/`repetition_end` (seconds, in the
*original* video). CSVs are ungated (already on disk before this task started).

**Conversion.** `tools/fixtures/countix_convert.py`. For each selected row:
`yt-dlp --download-sections` pulls only the `[kinetics_start, kinetics_end]`
window (never the whole video), `ffmpeg` re-encodes to a constant-frame-rate
`.mov` (`-r 30 -vsync cfr`) so frame-indexed ground truth stays valid, and a
sidecar is written with `repetition_start`/`repetition_end` converted from
original-video-relative seconds to clip-relative seconds and emitted as the
single `trueSetBoundaries` entry. No per-rep timestamps are invented — Countix
doesn't provide them, and interpolating them evenly would be fabricated data,
which the task explicitly forbids.

**Attrition (primary 4 classes).** 280 rows attempted (70 per class,
round-robined so early failures wouldn't starve one class), 171 distinct clips
resolved to disk (script log double-counts a handful of duplicate
video_id+start+end rows across train/val as 177; 171 is the true count of
files on disk, verified by listing).

| Class | Attempted | Resolved |
|---|---|---|
| bench pressing | 70 | 44 |
| squat | 70 | 43 |
| pull ups | 70 | 39 |
| push up | 70 | 45 |
| **total** | **280** | **171** |

Failure reasons (primary run): `age_or_login_restricted` 65 (see note below —
this is mostly YouTube bot-detection triggered by request volume, not real
per-video restriction), `other` 17, `unavailable_or_deleted` 12, `private` 8,
`ffmpeg_failed` 1.

**Note on `age_or_login_restricted`.** Partway through the run, yt-dlp started
returning "Sign in to confirm you're not a bot" (HTTP 429) for videos that are
not actually age-restricted — confirmed by manually re-running one flagged id
in isolation and getting the same 429/bot-check rather than a genuine
age-gate. This is YouTube's anonymous-request rate limiting responding to
concurrency-12 sustained traffic, not 65 individually blocked videos. A slower,
serialized or cookie-authenticated re-run would likely recover a meaningful
fraction of these; not attempted here to stay inside the time-box. Reported
as observed, not corrected for.

**Optional `exercising arm` class (dumbbell coverage attempt).** Attempted
because the primary four classes resolved quickly and MM-Fit/InfiniteRep (the
other intended dumbbell/bodyweight sources) both turned out unusable — see
below — leaving zero dumbbell coverage otherwise. Hit the same rate-limiting
wall almost immediately: 90 attempted, only 11 resolved (`age_or_login_restricted`
71, `private` 4, `unavailable_or_deleted` 4).

All 11 resolved clips were visually spot-checked (mid-clip frame per clip) to
set `equipment` from what's actually in frame rather than assumed from the
Countix class label — "exercising arm" turned out to cover dumbbell curls/rows
*and* med-ball throws, ab work, and at least one clip that isn't a gym
exercise at all (a baseball umpire adjusting his belt). Only clips that
genuinely show a hand-held dumbbell were kept as `equipment: dumbbell` (5 of
11); the rest were relabelled `equipment: bodyweight` with a `lightingNote`
that states no external weight was visible, rather than left as a
blanket-assumed `dumbbell` that would have been wrong for most of them.

**`exerciseId` mapping:** `bench pressing` → `bench_press`, `squat` →
`back_squat`, `pull ups` → `pull_up`, `push up` → `push_up`, `exercising arm`
→ `arm_exercise`.

**`equipment` mapping and a known impurity.** `bench_press`/`back_squat` →
`barbell`; `pull_up`/`push_up` → `bodyweight`. Countix's `squat` class mixes
barbell and bodyweight squats and the two were not disambiguated by watching
every clip — **all 43 squat clips are marked `barbell`**, which is wrong for
whichever subset are actually bodyweight squats. Flagging this as a known
impurity rather than a silently-wrong label: anyone tuning `back_squat`
scoring against this corpus should expect some bodyweight squats mislabelled
as barbell.

**`plateDiameterMm`: 450 on every barbell clip, assumed, not measured.** This
is safe for *counting* and unsafe for *velocity*: Track A's ratchet derives
its range-of-motion scale from the lifter's own first few reps, so a wrong
plate diameter cancels out of the rep count entirely, while it scales every
m/s figure it produces linearly. Count metrics from this corpus are
trustworthy; velocity metrics from it are not, and none of these clips carry
`referenceMeanConcentricVelocity` for exactly that reason.

**`cameraPosition` and `lightingNote`: hand-labelled from a real frame, not
guessed.** The `CameraPosition` enum has no "unknown" case, and the task is
explicit that fabricating a specific angle is worse than not having one — a
fabricated angle would produce a confident, meaningless accuracy-by-angle
breakdown. So a mid-clip frame was extracted from every resolved clip, tiled
into labelled contact sheets, and each clip's angle bucket and lighting were
assigned by actually looking at that frame (the same "roughly 30° off to the
left" standard the `CameraPosition` doc comment describes for hand-labelling
— not measured with a protractor, but not invented either). Distribution
across the 171 primary clips: perpendicular 67, oblique30 41, frontal90 25,
oblique45 22, oblique15 13, oblique60 3. A handful of very dark/unreadable
frames were bucketed `oblique30` with a `lightingNote` that says so explicitly
("dark / unclear lighting") rather than a confident-sounding guess.

**`licence`: `unverifiedCommercialUse` for every Countix clip.** Countix's
*annotations* are Google's, released CC-BY. The *videos* are third-party
YouTube uploads under YouTube's standard terms, not re-licensed by Google —
there is no blanket clearance for commercial redistribution of the footage
itself. `unverifiedCommercialUse` ("no explicit licence found... must be
verified before any commercial use, not assumed clean") is the closest fit
and the most restrictive of the enum's non-gated options; `allowsCommercialUse`
is `false`. These clips are local test fixtures only, never redistributed,
and the videos are gitignored — but the sidecar has to tell the truth
regardless of current usage, per SPEC §19 open question 9.

## RepCount-A — blocked

Homepage (`svip-lab.github.io/dataset/RepCount_dataset.html`) advertises no
request form or login, but the actual download links are a OneDrive folder
share and a Baidu NetDisk share, both of which are interactive web-app UIs
(confirmed: `curl` gets back `text/html`, not a file — there is no scriptable
direct-download URL, only a JS-driven folder browser). Even once fetched, the
package documented in the repo is metadata/annotations only; the videos still
require the same "youtube-dl against a list of ids" attrition process as
Countix, per the repo's own instructions. Recorded as blocked after this
"honest effort", not pursued further per the task's time-box.

## MM-Fit — downloaded, unusable

The ungated zip (`https://s3.eu-west-2.amazonaws.com/vradu.uk/mm-fit.zip`,
1.7 GB) downloaded cleanly with no gate. Inspected the full archive listing
(`unzip -l`, no partial download): it contains only wearable-sensor streams
(`*_acc.npy`, `*_gyr.npy`, `*_hr.npy`, `*_mag.npy`), 2D/3D pose keypoint
arrays, and a `*_labels.csv` per subject (which *does* carry real rep counts
and exercise names, including `dumbbell_shoulder_press`/`dumbbell_rows`).
**Zero RGB/video files anywhere in the archive** (`unzip -l | grep -c
'mp4\|avi\|mov\|mkv'` → 0). The paper describes multi-viewpoint RGB-D video
being recorded, but the public distribution does not include it — most
likely withheld for subject privacy. Without a video, there is nothing to
put in a `.mov`; rendering the pose keypoints into a synthetic animation
would not be real footage, which the task explicitly rules out. No dumbbell
coverage came from this source.

## InfiniteRep — downloaded, unusable, and not the licence the task assumed

The task states InfiniteRep is CC BY 4.0. The original Infinity AI
distribution is gone (Infinity AI is no longer operating); the only copy
found is a third-party "rescue" mirror on Hugging Face
(`FatimahEmadEldin/infiniterep-physiotherapy`). Its actual stated licence is
`license: other`, `license_name: infiniterep-research-use` — **research use
only, not commercially clean** — which contradicts the task's premise. Beyond
the licence mismatch, the archive itself is not usable for fixtures:

- The per-instance ZIPs (`data/<split>/<exercise>/<id>_img_labels.zip`)
  contain only segmentation-mask PNGs (`*.iseg.*.png`, `*.cseg.png`) — no RGB
  frames, no keypoint coordinate files. Spot-checked one (`armraise/000005`):
  1,645 files, all masks.
  and 160 of the archive's 720 train-split zip entries are outright corrupt
  (`error: "File is not a zip file"`).
- The parquet manifests (`train.parquet`/`dev.parquet`/`test.parquet`) that
  index the archive have **no rep-count column at all** — only `exercise`,
  `instance_id`, path metadata, `n_frames`, and a `kp_coverage` score (which
  reads `0.0` on every inspected row). There is no ground truth to build
  `trueRepCount` from without inventing it.

Recorded as unusable rather than forced: this is exactly the "never
fabricate" line the task draws, on two axes (footage and count) at once. No
bodyweight coverage came from this source; the 84 bodyweight clips in the
corpus are Countix `pull_up`/`push_up` only.

## Summary

- **182** fixtures total, all from Countix: `bench_press` 44, `back_squat` 43,
  `pull_up` 39, `push_up` 45, `arm_exercise` 11.
- Equipment: **barbell** 87, **bodyweight** 90, **dumbbell** 5. All three of
  the task's required equipment classes are represented, though dumbbell
  coverage is thin (5 clips) — MM-Fit and InfiniteRep, the two sources meant
  to cover dumbbell and bodyweight respectively, both turned out to have no
  usable video (see above), so all 5 dumbbell clips come from a single
  Countix class that mostly wasn't dumbbell work. **Machine** equipment is
  not represented at all.
- Every clip: `licence: unverifiedCommercialUse`, `allowsCommercialUse: false`.
  None of this corpus may ship in a commercial product without a fresh,
  clip-by-clip licence check — filter on `licence.allowsCommercialUse` before
  that ever matters, per SPEC §19 open question 9.
- No clip in this corpus carries `referenceMeanConcentricVelocity` — found
  footage has no criterion velocity measurement, so §15.2's velocity RMSE
  target is not scoreable against this corpus at all, only against a future
  clip with a known criterion (per the task notes).
- `fixtures/countix/` sits directly under `fixtures/`, not `fixtures/`'s own
  top level — `FixtureLoader.load(directory:)` does **not** recurse into
  subdirectories (confirmed by reading `FixtureLoader.swift`: it calls
  `contentsOfDirectory` once, non-recursively). Pointing `timmethod-eval
  --fixtures fixtures` at the repo root therefore finds only the three
  original example clips, not this corpus — run it against
  `fixtures/countix` directly (see the eval CLI summary in the task report).
  This is a pre-existing loader limitation, not something introduced here;
  flagging it since the task's own "where things go" layout
  (`fixtures/<source>/…`) only works today if each source directory is
  pointed at individually.
