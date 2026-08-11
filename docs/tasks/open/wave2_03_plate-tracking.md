# W2-03 · Frame-to-frame plate tracking

**Wave:** 2 — Track A: Plate Tracking
**Status:** open
**Depends on:** W2-01
**Spec:** §8

## Goal
Follow the detected plate cheaply across frames, and survive brief occlusion.

## Why
Full detection every frame is wasteful and jitters. Tracking is both faster and smoother, and occlusion by a hand or a rack upright is routine, not exceptional.

## Do
- [ ] Local search around the previous centroid, with a search radius derived from plausible bar velocity
- [ ] Periodic full re-detection (every N frames, and always after a loss) to prevent drift
- [ ] Interpolate through up to 5 lost frames, then declare tracking lost
- [ ] Emit a per-frame tracking confidence that the counter can gate on
- [ ] On loss, freeze counting rather than guessing — surface it to the UI later

## Done when
- [ ] A clip with a deliberate 3-frame hand occlusion counts correctly
- [ ] A clip where the plate leaves frame entirely reports tracking lost rather than emitting garbage reps

## Notes
The 5-frame interpolation window matches what is reported working for pose landmark dropouts in production. Same principle, different signal.
