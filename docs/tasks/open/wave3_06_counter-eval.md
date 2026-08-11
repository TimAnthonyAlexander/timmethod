# W3-06 · Score the counter to target

**Wave:** 3 — Rep Counter
**Status:** open
**Depends on:** W3-04, W3-05, W1-05
**Spec:** §15.2

## Goal
Clear the §15.2 **target** column on loaded exercises, not just the floor.

## Why
Everything after this wave assumes the count is right. Shipping a floor-grade counter means every later feature is built on a number the user does not trust.

## Do
- [ ] Full harness run across all loaded fixtures
- [ ] Tune `A_min` fraction, debounce floor and `C_min` against the set — never against a live camera
- [ ] Per-exercise and per-camera-angle breakdown
- [ ] Wire the CLI's non-zero exit into a `make check` regression gate
- [ ] Write the resulting parameter set into a versioned config, not scattered constants

## Done when
- [ ] Count MAE ≤ 0.05 and off-by-one ≥ 98% on loaded fixtures
- [ ] Zero false-positive reps across the whole fixture set
- [ ] Regression gate is live and a deliberate parameter regression fails the build

## Notes
This is the wave where the product either works or does not. Do not move to Wave 4 on floor-grade numbers.
