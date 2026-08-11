# W5-08 · Backend bake-off and decision

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-05, W5-07, W1-05
**Spec:** §4.1, §19

## Goal
Run both providers over the same fixtures and settle §4.1 with data. Close open question 1.

## Why
The default was chosen on integration cost and thermals because those are evidenced. Accuracy between these two backends is unmeasured by anyone. This is where that stops being true.

## Do
- [ ] Full harness run, both providers, identical fixtures
- [ ] Compare: count MAE, off-by-one, ROM consistency across camera angles, tracking-loss rate, inference latency, sustained thermal behaviour over a simulated 45-minute session
- [ ] Break down by exercise — the winner may differ between bodyweight and loaded
- [ ] Measure static-subject jitter for both, closing open question 2 and settling W3-01's smoothing default
- [ ] Write the result into `docs/SPEC.md` §4.1, replacing the provisional reasoning with measurements
- [ ] Decide: single backend, or per-exercise selection

## Done when
- [ ] A comparison table exists in the spec with real numbers
- [ ] The default provider is set from data, and the reasoning is recorded
- [ ] Open questions 1 and 2 are closed or explicitly re-scoped

## Notes
If MediaPipe wins on accuracy, the 430 MB force-load and CocoaPods dependency become a real cost to weigh rather than a reason to avoid it. Weigh it honestly against the measured accuracy gap; do not let the earlier default become self-justifying.
