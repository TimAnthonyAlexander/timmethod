# W6-05 · Preview and overlay

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W6-02, W6-04
**Spec:** §14.2

## Goal
Live camera with skeleton, plate ellipse and bar path drawn over it.

## Why
The bar path is the one genuinely beautiful thing this app draws and should be the thing people screenshot.

## Do
- [ ] SwiftUI `Canvas`, **redrawn only when new tracker output arrives** — not on a `CADisplayLink`
- [ ] Thin bone skeleton at low opacity
- [ ] Track A: fitted plate ellipse plus the bar path trailing in the sagittal plane, in metres
- [ ] Hold the last skeleton between inference frames rather than interpolating
- [ ] Coordinate transform from world/normalized space to view space, handling front-camera mirroring
- [ ] Overlay toggleable, and force-off under thermal pressure

## Done when
- [ ] Overlay tracks the subject with no visible lag at 60fps capture
- [ ] Energy impact measured over a 10-minute session and recorded
- [ ] Bar path renders correctly for squat, bench and overhead press

## Notes
`Canvas` under continuous animation-driven redraw has a reported energy and thermal cost, which is exactly why redraw is gated on data arrival. A 17–33 point skeleton is a trivial draw-call count and is not the frame budget.
