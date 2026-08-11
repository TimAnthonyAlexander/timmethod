# W4-03 · Velocity loss per set

**Wave:** 4 — Velocity
**Status:** open
**Depends on:** W4-02
**Spec:** §8.1, §11.1

## Goal
`VL% = (first-rep MCV − current-rep MCV) / first-rep MCV`, live during the set.

## Why
Velocity loss tracks proximity to failure tightly — r = 0.97 on bench and r = 0.93 on squat against percentage of reps completed. It is the stop cue the whole method turns on.

## Do
- [ ] Establish the first-rep reference; discard it and re-reference if rep 1 was clearly mistracked
- [ ] Compute running VL% after every rep
- [ ] Use best-of-first-two as the reference rather than literally rep 1, to blunt a single bad measurement
- [ ] Store final `velocityLossPct` on the set
- [ ] Expose a live stream for the UI instrument

## Done when
- [ ] VL% curve on a to-failure fixture rises monotonically apart from noise
- [ ] A mistracked first rep does not corrupt the whole set's VL

## Notes
The set-level number is what gets stored; the live stream is what drives the bar in §14.1.
