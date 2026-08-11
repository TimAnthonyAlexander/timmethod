# W5-05 · PCA projection to RepSignal

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-03, W1-07
**Spec:** §6

## Goal
Turn landmark trajectories into the same 1D `RepSignal` Track A produces.

## Why
One counter, two sources. This is the second source. The approach is not invented here — project landmark motion onto PCA axes in a sliding window, then zero-cross with debounce, which is what NEX Team patented and shipped.

## Do
- [ ] Sliding-window PCA over the active joint set for the exercise
- [ ] Project onto the first principal component
- [ ] Scale: `plateDiameter` when Track A is concurrently available, else `lidarBodyHeight`, else `referenceHeight`, else `torsoRelative`
- [ ] Stabilise the component sign across windows so the signal does not flip
- [ ] Fall back to a named joint's displacement when PCA is degenerate (near-zero variance)

## Done when
- [ ] A bodyweight squat fixture produces a clean quasi-sinusoidal signal
- [ ] Component sign never flips mid-set
- [ ] The counter from Wave 3 consumes it unchanged, with no pose-specific code

## Notes
"The counter consumes it unchanged" is the acceptance test that matters. If Track B needs counter changes, the abstraction is wrong.
