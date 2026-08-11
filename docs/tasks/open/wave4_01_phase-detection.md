# W4-01 · Concentric and eccentric phase split

**Wave:** 4 — Velocity
**Status:** open
**Depends on:** W3-06
**Spec:** §8.1, §12

## Goal
Split each accepted rep into its concentric and eccentric phases with real boundaries.

## Why
Mean concentric velocity is the quantity everything in the Tim Method layer depends on. The phase boundary defines it.

## Do
- [ ] Boundary at the velocity zero crossing at the bottom of the rep
- [ ] Determine which direction is concentric per exercise (squat up, deadlift up, bench up, curl up — but a pulldown is down)
- [ ] Store `concentricMs` and `eccentricMs` per rep
- [ ] Handle a paused rep (bench with a pause) without attributing the pause to either phase

## Done when
- [ ] Phase durations on an annotated fixture match hand-marked boundaries within 2 frames
- [ ] A paused bench fixture reports the pause separately rather than inflating the concentric

## Notes
Tempo gets recorded because it is free, not because it gets coached. §11.5 — the evidence says tempo does not matter for hypertrophy.
