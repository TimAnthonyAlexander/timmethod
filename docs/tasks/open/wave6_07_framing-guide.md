# W6-07 · Framing and setup guide

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W6-05
**Spec:** §14.3

## Goal
Get the camera placed correctly before the set, and remember it next time.

## Why
Camera-angle error is the documented top failure mode, with accuracy degrading past roughly 30° off-perpendicular. The mitigation that reportedly works is an on-screen placement guide that enforces it.

## Do
- [ ] Framing overlay showing the required capture box, with live pass/fail on full-body visibility
- [ ] Off-axis warning when the estimated camera angle exceeds ~30°
- [ ] Backlighting and low-light warnings — both drop landmark confidence measurably
- [ ] **Plate visibility check before a loaded set.** If no plate of the configured diameter is found, say so *before* the set, because Track A is about to be unavailable
- [ ] Save framing per exercise so the second session does not renegotiate it
- [ ] A "ready" state that is unambiguous

## Done when
- [ ] Deliberately bad placements each produce the correct specific warning
- [ ] Saved framing is restored per exercise
- [ ] The plate check fires before the set, never after

## Notes
Warning after a set is worthless. The whole value of this screen is that it fires while the situation is still fixable.
