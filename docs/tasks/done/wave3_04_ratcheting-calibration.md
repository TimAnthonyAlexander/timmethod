# W3-04 · Ratcheting calibration

**Wave:** 3 — Rep Counter
**Status:** done
**Depends on:** W3-03
**Spec:** §7.3

## Goal
Establish `A_min` per set from the lifter's own range, and never let fatigue erode it.

## Why
Rolling auto-calibration that tracks observed extremes will count half reps. As a lifter fatigues, ROM shrinks; thresholds that follow the shrinkage down keep counting exactly the rep the counter exists to reject.

## Do
- [ ] Establish range from the **first three accepted reps** of a set
- [ ] `A_min` = 80% of established amplitude
- [ ] Within a set, range **expands only**. A larger rep raises the baseline; a smaller one never lowers it
- [ ] 50–80% of range → recorded as a **partial**: separate ledger, shown in the set summary, excluded from the working count
- [ ] Below 50% → not a rep
- [ ] Across sessions, the per-exercise baseline is the **median of session maxima**, not a running mean

## Done when
- [ ] A to-failure fixture where ROM visibly collapses counts full reps and partials separately, matching hand annotation
- [ ] One unusually deep warm-up rep does not permanently raise the session standard
- [ ] One bad session does not erode the cross-session baseline

## Notes
This is engineering judgment, not prior art — no shipped mitigation for fatigue ROM drift is documented anywhere. Open question 6. The to-failure fixture is the only real test, so record one specifically for this.
