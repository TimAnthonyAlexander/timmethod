# Fixtures

A fixture is a `.mov` clip plus a `.json` sidecar of the same base name
(`squat.mov` + `squat.json`) carrying ground truth. `FixtureLoader`
(`core/Sources/TimMethodCore/Fixtures/FixtureLoader.swift`) walks this
directory, pairs the two, decodes and validates the sidecar against the
`Fixture` schema (`core/Sources/TimMethodCore/Fixtures/Fixture.swift`), and
hands `ReplayFrameSource` the video and the eval harness the ground truth.

Video files are **not committed** (see "Videos are gitignored" below), except
the three tiny example clips this directory ships with. Sidecars and this
README are tracked — they're the ground truth and the valuable, reviewable
part.

## Schema (`fixture.json`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `exerciseId` | string | yes | Matches `Exercise.id` (SPEC §12), e.g. `"back_squat"`. Not the display name. |
| `equipment` | enum | yes | `barbell` \| `dumbbell` \| `bodyweight` \| `machine` |
| `plateDiameterMm` | number, nullable | no | Diameter of the tracked plate/end-cap in mm. Never set on `bodyweight` — the loader rejects it. Must be positive when present. |
| `trueRepCount` | int | yes | Total reps in the clip. Never negative. Zero is valid (e.g. a false-positive test clip). |
| `truePartialCount` | int | yes (default 0) | How many of `trueRepCount` were partial (50–80% ROM) reps. A subset of `trueRepCount`, not additional — must be `≤ trueRepCount`. |
| `cameraPosition` | enum | yes | `perpendicular` (0°) \| `oblique15` \| `oblique30` \| `oblique45` \| `oblique60` \| `frontal90` (90°). SPEC §14.3: accuracy degrades past ~30° off-perpendicular, so results get broken down by this. |
| `lightingNote` | string | yes | Free text, e.g. `"overhead LED, no backlight"`. Lets a failing clip be triaged to a lighting cause without re-watching it. |
| `sourceDataset` | string | yes | `"FLEX"` \| `"MM-Fit"` \| `"Fitness-AQA"` \| `"InfiniteRep"` \| `"RepCount-A"` \| `"own"` (SPEC §15.1). Provenance for humans; `licence` is what code checks. |
| `licence` | enum | yes | `ccBy4` \| `ccByNcSa4` \| `nonCommercialGated` \| `openUnrestricted` \| `unverifiedCommercialUse` \| `ownFootage`. Has an `allowsCommercialUse: Bool` — filter on it before ever shipping the fixture set (SPEC §19 open question 9: FLEX and Fitness-AQA are non-commercial). |
| `perRepTimestamps` | [number], nullable | no | Seconds, clip-relative, one per counted rep, oldest first. Must be strictly increasing when present. |
| `referenceMeanConcentricVelocity` | [number], nullable | no | m/s, one per rep, same order as `perRepTimestamps`. **Only** set when a criterion measurement exists (linear encoder, published dataset ground truth) — scores SPEC §15.2's ≤0.05 m/s RMSE target. Each value must be positive. |
| `trueSetBoundaries` | [{startTime, endTime}], nullable | no | Seconds, clip-relative. Scores SPEC §15.2's ≥0.95 set-boundary F1 target. `endTime > startTime` per boundary; boundaries must not overlap or go out of order. |

**Absent means "not scoreable for this metric," never "zero."** Most clips
will not carry `referenceMeanConcentricVelocity` or `trueSetBoundaries` —
that's expected, not a gap to fill in. A clip missing them is simply excluded
from those two metrics' scoring, the same way a clip missing
`perRepTimestamps` is excluded from per-rep timing diagnostics.

## Adding a clip

1. Drop the video in as `<name>.mov`.
2. Write `<name>.json` with at least the required fields above.
3. Run the loader (or `timmethod-eval`, once W1-05 lands) against this
   directory and confirm your fixture loads with no validation error.
4. If the source is a published dataset, set `sourceDataset` and `licence`
   accurately — this is the field that has to answer "can this ship" without
   anyone re-reading the file later.

## Validation errors

The loader never crashes on a bad sidecar and never aborts a batch: one bad
fixture is reported and skipped, so a run over hundreds of clips still scores
every clip that *is* valid. Errors always name the offending file. Checked:

- missing `.json` sidecar for a `.mov`, or missing `.mov` for a `.json`
- sidecar unreadable or not valid JSON, or JSON that doesn't match the schema
- `trueRepCount` or `truePartialCount` negative
- `truePartialCount` greater than `trueRepCount`
- `perRepTimestamps` not strictly increasing
- `plateDiameterMm` set on a `bodyweight` exercise, or not positive
- `referenceMeanConcentricVelocity` entries not positive
- `trueSetBoundaries` entries with `endTime ≤ startTime`, or overlapping /
  out-of-order boundaries

## Videos are gitignored

Fixture videos are large and some source datasets (FLEX, Fitness-AQA) are
licence-restricted, so `.mov` files under this directory are gitignored by
default. The three example clips — `barbell_back_squat.mov`,
`dumbbell_row.mov`, `bodyweight_pushup.mov` — are committed as explicit
exceptions in the root `.gitignore`, so a fresh clone has something real to
run the loader against without regenerating anything.

They're synthetic: a handful of solid-colour frames written with
`AVAssetWriter`, not real lifts, only useful for exercising the loader and
schema. To regenerate them, or to create more like them, use
`core/Tests/TimMethodCoreTests/TestMovieWriter.swift` as a reference for the
`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` pattern — write a
standalone script rather than importing test code into the library or the
fixture set.
