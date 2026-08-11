# W9-05 · Score enrollment and recognition

**Wave:** 9 — Few-shot Enrollment
**Status:** open
**Depends on:** W9-03, W1-05
**Spec:** §15

## Goal
Numbers on few-shot counting and recognition, from held-out fixtures.

## Why
The published few-shot results transfer in concept but not in number — they are IMU-based, not pose-based. Ours have to be measured.

## Do
- [ ] Hold out movements from the fixture set, enroll from 2–3 cycles, score counting on the rest
- [ ] Confusion matrix across all enrolled movements
- [ ] Score how enrollment example count (1, 2, 3, 5) affects both counting and recognition
- [ ] Record where recognition fails and whether the 1D signal or the trajectory was the weaker cue

## Done when
- [ ] Few-shot counting MAE is within 2× of the hand-modelled exercises' MAE
- [ ] Recognition confusion matrix exists and is in the report
- [ ] The optimal enrollment example count is chosen from data and the UI reflects it

## Notes
If few-shot counting is close to hand-modelled counting, that is a genuinely publishable result — no head-to-head between class-agnostic counting and hand-tuned state machines exists anywhere in the literature.
