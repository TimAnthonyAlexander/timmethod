# W3-03 · Amplitude gate

**Wave:** 3 — Rep Counter
**Status:** open
**Depends on:** W3-02
**Spec:** §7.2

## Goal
Accept a candidate rep on swept displacement, not on how long it took.

## Why
Time-based debounce punishes fast reps. `MIN_PHASE_MS` of 150–250ms assumes a pause at the bottom that explosive lifters do not take, and missing a real rep is worse than counting a twitch. Amplitude rejects noise for the same reason and is speed-neutral.

## Do
- [ ] Accept iff peak-to-valley amplitude ≥ `A_min`
- [ ] AND phase duration ≥ 80 ms (spike floor only, not the primary gate)
- [ ] AND mean confidence over the cycle ≥ `C_min`
- [ ] AND the posture gate held throughout (W3-05)
- [ ] `A_min` in metres when scale is `plateDiameter` or `lidarBodyHeight`; as a fraction of torso length otherwise
- [ ] Emit a rejection reason on every rejected candidate, into the trace

## Done when
- [ ] A fast-rep fixture (sub-150ms bottom) counts correctly
- [ ] A twitch/adjustment fixture counts zero
- [ ] Every rejection in a scored run has a machine-readable reason

## Notes
Rejection reasons are what make a wrong count debuggable. Without them you get "it said 9 instead of 10" and no way forward.
