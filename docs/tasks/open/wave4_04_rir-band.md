# W4-04 · RIR band from velocity loss

**Wave:** 4 — Velocity
**Status:** open
**Depends on:** W4-03
**Spec:** §8.1, §11.1

## Goal
Translate VL% into reps-in-reserve, expressed as a **band**, never a single integer.

## Why
The group-level correlation is strong but individual variability is real: coefficient of variation for rep completion at matched velocity loss is 15–22% on bench and 26–34% on squat. A single confident integer would misrepresent the measurement.

## Do
- [ ] Per-exercise VL → %reps-completed mapping, seeded from published bench and squat relationships
- [ ] Convert to an RIR band whose width reflects the published CV for that exercise class
- [ ] **Widen the band as session fatigue accumulates** — velocity-at-failure reliability degrades under fatigue and short rest
- [ ] Never render a bare integer RIR anywhere in the UI
- [ ] Personalise the mapping over time from the user's own to-failure sets, once enough exist

## Done when
- [ ] Bands are wider on squat than bench, matching the published CV difference
- [ ] Band widens measurably across a long session
- [ ] No code path can produce a point-estimate RIR

## Notes
This is one of the honesty-page entries (§17.1). State the CV numbers plainly rather than hiding them behind a clean number.
