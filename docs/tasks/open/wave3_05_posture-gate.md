# W3-05 · Posture gate

**Wave:** 3 — Rep Counter
**Status:** open
**Depends on:** W1-07
**Spec:** §7.1

## Goal
Refuse to count unless the lifter is plausibly performing the exercise.

## Why
Confidence is not the same question as "is this person lifting." Standing up, walking to the rack and lying down all sweep the full signal range. Without this gate the counter fires during setup, and the first thing anyone sees is a broken number.

## Do
- [ ] Torso orientation relative to gravity as the primary cue
- [ ] Coarse landmark layout check (are the joints arranged like the expected posture at all)
- [ ] For Track A without pose: plate presence, plausible plate height range, and stationarity of the non-working axis
- [ ] Gate opens and closes with hysteresis so it does not chatter at the boundary
- [ ] Gate state recorded per frame in the trace

## Done when
- [ ] A fixture containing setup, a set, and racking counts only the set's reps
- [ ] A fixture of someone walking past the camera counts zero

## Notes
Cheap heuristics are enough here. This does not need a model.
