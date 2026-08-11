# W10-03 · Camera-active indicator

**Wave:** 10 — Ship Readiness
**Status:** open
**Depends on:** W6-04, W6-05
**Spec:** §17

## Goal
A persistent, visible indication whenever the camera is running.

## Why
Guideline 2.5.14 requires a clear visual or audible indication while actively recording via camera or microphone. With a camera running for a whole workout this is not optional.

## Do
- [ ] Persistent on-screen indicator whenever capture is active
- [ ] Designed into the layout rather than bolted on — it is present for the entire session, so it has to look intentional
- [ ] Visible in every state including thermal-degraded and overlay-off
- [ ] Distinct from the accent colour, whose one meaning is "stop the set"
- [ ] Capture demonstrably stops when the session ends, and the indicator goes with it

## Done when
- [ ] Indicator is present in every camera-active state
- [ ] Backgrounding stops capture and the indicator
- [ ] It does not read as decoration

## Notes
The accent is reserved. Use the bone token at a distinct treatment, not a second colour, or the palette discipline in §14.1 breaks on the one screen people look at longest.
