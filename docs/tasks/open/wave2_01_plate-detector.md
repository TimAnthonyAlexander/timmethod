# W2-01 · Plate detector core

**Wave:** 2 — Track A: Plate Tracking
**Status:** open
**Depends on:** W1-03
**Spec:** §8

## Goal
Find the weight plate in a frame and return a fitted ellipse.

## Why
This is the primary signal for every loaded exercise. Three independent shipped VBT products converge on tracking a known-diameter circle rather than the bar or the body, and it is the only approach in this space with peer-reviewed validation.

## Do
- [ ] Edge/gradient pass, then ellipse fit constrained by an expected radius range derived from the configured plate diameter and plausible subject distance
- [ ] Fit an **ellipse, not a circle** — the plate projects to an ellipse off-axis and the major axis is the true diameter, rotation-invariant
- [ ] Return centre, major axis length in px, minor axis, orientation, fit residual as confidence
- [ ] Reject fits whose eccentricity implies an impossible camera angle
- [ ] Handle two plates in frame (both ends of a dumbbell, or a second lifter) by scoring and picking one, deterministically

## Done when
- [ ] Detects the plate on ≥95% of frames across a 20-clip FLEX barbell subset
- [ ] Runs in ≤5 ms per frame on the dev device
- [ ] Unit tests on synthetic ellipses at known angles recover the major axis to within 1%

## Notes
Chrome plates under gym fluorescents may defeat gradient-based fitting — this is open question 3. If it fails, note exactly how before reaching for a fallback; a coloured band on the plate is marker friction the whole design rejects.
