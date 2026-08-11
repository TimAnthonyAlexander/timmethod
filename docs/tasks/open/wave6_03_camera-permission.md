# W6-03 · Camera permission flow

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W6-02
**Spec:** §17

## Goal
Request camera access with copy that says what actually happens.

## Why
Generic usage strings draw ITMS-90738 rejections, and the honest version is also the better product.

## Do
- [ ] `NSCameraUsageDescription`: "Tim Method uses your camera to measure how far and how fast the weight moves, so it can count your reps and track your range of motion. Video is processed on your iPhone and never leaves it."
- [ ] Pre-permission explainer screen before the system prompt
- [ ] Denied state: a real explanation and a deep link to Settings, not a dead end
- [ ] Restricted and provisional states handled

## Done when
- [ ] All permission states produce a sensible screen
- [ ] Fresh install to first frame works in one pass

## Notes
The pre-prompt explainer is worth it. A cold system dialog on first launch converts worse and tells the user nothing.
