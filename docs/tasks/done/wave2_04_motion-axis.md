# W2-04 · Motion axis fit and 1D projection

**Wave:** 2 — Track A: Plate Tracking
**Status:** done
**Depends on:** W2-03, W1-07
**Spec:** §6, §8

## Goal
Turn a 2D centroid trace into the scalar `RepSignal` the counter reads.

## Why
The counter is one implementation over a 1D signal. Everything upstream exists to produce that signal well.

## Do
- [ ] Fit the dominant motion axis over a sliding window (first principal component of the centroid trace)
- [ ] Project the centroid onto it, in metres, sign-oriented so positive is away from the ground
- [ ] Retain the perpendicular component separately — that is horizontal bar deviation, useful for bar path, not for counting
- [ ] Handle a squat (near-vertical axis) and a bench press (near-vertical but from a side-on camera) without special-casing either
- [ ] Emit into `RepSignal` with `ScaleSource.plateDiameter`

## Done when
- [ ] A squat clip produces a clean quasi-sinusoidal 1D signal
- [ ] Axis fit remains stable when the lifter's bar path drifts forward during a fatiguing set

## Notes
Fitting the axis rather than assuming vertical is what makes bench press and overhead press work with the same code. Do not hardcode gravity as the axis.
