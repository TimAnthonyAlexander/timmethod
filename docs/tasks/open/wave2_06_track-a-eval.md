# W2-06 · Score Track A against fixtures

**Wave:** 2 — Track A: Plate Tracking
**Status:** open
**Depends on:** W2-04, W1-05, W1-06
**Spec:** §15.2

## Goal
Numbers, on real clips, for detection rate and signal quality.

## Why
Wave 3 tunes a counter. Tuning a counter on a bad signal wastes the whole wave.

## Do
- [ ] Run the CLI over all FLEX barbell and MM-Fit dumbbell fixtures
- [ ] Report: detection rate per clip, mean tracking confidence, scale stability, frames lost
- [ ] Break results down by camera angle (FLEX has 5 per subject — use them)
- [ ] Identify and file the worst-performing exercise and camera angle as their own follow-up

## Done when
- [ ] ≥95% plate detection rate across the barbell subset
- [ ] Per-camera-angle table exists and is written into the report
- [ ] Bench press is scored specifically and its result recorded, since it is open question 4

## Notes
Bench press is the interesting case. Pose fails on it industry-wide; plate tracking should not. If it does, that is a significant finding and changes v1 scope.
