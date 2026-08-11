# W9-03 · DTW recognition

**Wave:** 9 — Few-shot Enrollment
**Status:** open
**Depends on:** W9-02
**Spec:** §9.3

## Goal
Identify which enrolled movement a completed rep belongs to.

## Why
Zero manual exercise selection during a workout. Published support is decent, if adjacent: 86.8% on 28 unseen exercises via a Siamese/triplet approach, and 95% for one-shot template matching on five.

## Do
- [ ] DTW distance from a completed, normalized cycle against every enrolled template
- [ ] Combine the 1D signal distance with the landmark trajectory distance
- [ ] Reject with "unknown movement" below a confidence threshold rather than forcing a match
- [ ] **Classify completed cycles only. Never gate counting on recognition**
- [ ] Lock the identity for the set once three consecutive reps agree, so mid-set flapping is impossible
- [ ] Correction affordance that adds the corrected cycle to that template

## Done when
- [ ] Recognition accuracy ≥90% across all enrolled v1 movements
- [ ] Squat and deadlift are reliably distinguished
- [ ] A movement not enrolled reports unknown rather than picking the nearest wrong answer

## Notes
Ordering matters here and it is deliberate. Full-sequence DTW is well-behaved but the published pose-domain work is not streaming, and PoseSync's accuracy drops to 62–87% under action reordering — which is what fatigue drift and partial reps look like to a fixed template. So the amplitude counter accepts a rep first, and DTW only labels it.
