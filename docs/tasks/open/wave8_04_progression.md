# W8-04 · Progression rule

**Wave:** 8 — Tim Method Engine
**Status:** open
**Depends on:** W8-03, W7-05
**Spec:** §11.6

## Goal
Decide next session's load, from reps and first-rep velocity.

## Why
Velocity-anchored double progression. The velocity gate is the evidenced part; double progression itself is an expert heuristic with no study isolating it, and is labelled as such.

## Do
- [ ] Increase load when all sets hit the top of the rep range **and** first-rep velocity was at or above the floor for that load
- [ ] Hold when reps hit but velocity was low — that is fatigue, not readiness
- [ ] Build the per-exercise velocity floor from the user's own history at that load, not a population table
- [ ] Suggest, never auto-apply. The lifter confirms
- [ ] Show the reasoning in one line: which condition passed and which did not

## Done when
- [ ] Progression suggestions on synthetic history match hand-computed expectations
- [ ] A high-rep-but-slow session correctly withholds the increase
- [ ] Reasoning is visible for every suggestion

## Notes
Do not claim a periodization model. LP versus DUP is d = −0.02, and the periodization-beats-non-periodization result is confounded — a re-examination of all 21 underlying studies found none compared it against a *varied* non-periodized program.
