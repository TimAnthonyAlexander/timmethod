# W5-03 · Per-joint confidence gating

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-02
**Spec:** §7.1

## Goal
Keep usable frames, discard unusable joints, and never feed a garbage coordinate into the angle math.

## Why
A single global confidence threshold throws away usable frames and keeps unusable ones. Per-body-part floors are what is reported working in production.

## Do
- [ ] Per-joint confidence floors, configurable per exercise (squat hips can go as low as 0.2; wrists on a loaded bar need more)
- [ ] Interpolate through low-confidence stretches up to 5 frames, then declare loss
- [ ] Hard anatomical constraints as a validity filter — knee cannot be above hip, limb segment lengths cannot change between frames
- [ ] **Side selection**: take the higher-confidence side per frame, or a confidence-weighted average. Never a naive mean
- [ ] Surface a "tracking lost, reposition" state when too many active joints fail for too long

## Done when
- [ ] A clip with one side occluded throughout counts correctly using the visible side
- [ ] Anatomically impossible frames are rejected and logged
- [ ] Tracking-lost fires on a genuine loss and not on a 3-frame dropout

## Notes
Wrist landmarks are the generic weak point — 7.74° mean absolute error on wrist angle even without a bar, attributed to small, easily occluded hand keypoints. Grip on a barbell is that plus the bar occluding the hand.
