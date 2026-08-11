# W4-05 · Score velocity accuracy

**Wave:** 4 — Velocity
**Status:** open
**Depends on:** W4-02, W1-05
**Spec:** §15.2

## Goal
Velocity RMSE against reference, per exercise.

## Why
The velocity number drives load progression. A biased velocity produces a systematically wrong training plan.

## Do
- [ ] Add velocity metrics to the CLI report
- [ ] Score against FLEX reference where available; note explicitly where no reference exists
- [ ] Check for systematic bias, not just RMSE — a consistent underestimate is worse than symmetric noise
- [ ] Break down by camera angle

## Done when
- [ ] RMSE ≤ 0.05 m/s on exercises with reference data
- [ ] Bias is reported separately from RMSE and is near zero
- [ ] Exercises with no reference velocity are listed as unvalidated rather than silently passing

## Notes
Metric VBT's documented failure was systematic underestimation at higher velocities. Look for exactly that shape.
