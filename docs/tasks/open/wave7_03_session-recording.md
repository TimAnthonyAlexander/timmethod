# W7-03 · Session recording

**Wave:** 7 — Sessions & Persistence
**Status:** open
**Depends on:** W7-01, W7-02
**Spec:** §12

## Goal
Wire the live pipeline into persisted sessions, sets and reps.

## Why
Everything so far computes numbers and discards them.

## Do
- [ ] Session lifecycle: start, active, paused, ended, with crash recovery
- [ ] Sets written on segmentation boundary, not on app exit
- [ ] Reps written as they are accepted, so a crash loses at most one
- [ ] Load entry: manual per set, remembered per exercise, with fast adjust
- [ ] `stopReason` recorded accurately, including `.trackingLost`
- [ ] Thermal events attached to the session

## Done when
- [ ] A force-quit mid-set loses at most one rep
- [ ] A full session records without a single manual set boundary
- [ ] `stopReason` distributions look sane across a week of use

## Notes
Load is the one thing the camera cannot read. Keep entry to a single tap when the load is unchanged, which it usually is.
