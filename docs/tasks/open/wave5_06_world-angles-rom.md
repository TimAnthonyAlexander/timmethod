# W5-06 · World-space angles and ROM as percentage

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-03
**Spec:** §7.4

## Goal
Compute joint angles in world space, and never display an absolute degree value.

## Why
Rode et al. found knee flexion error ≥ 9.3° and **elbow flexion error ≥ 21.5°** in 2D, across every one of eleven models tested. A ±21° band swamps any threshold worth setting. But the error is largely systematic for a fixed camera and subject, so relative comparison holds where absolute does not.

## Do
- [ ] Angle math on **world coordinates**, never image space — a 2D projected angle depends on camera azimuth, and accuracy degrades past ~30° off-perpendicular
- [ ] Compute ROM per rep in metres and as `romPctOfBaseline`
- [ ] `romPctOfBaseline` is the only ROM number the UI may render
- [ ] Form flags expressed as deviation from the user's own baseline, never a population norm
- [ ] Absolute angles retained internally and in the trace for debugging

## Done when
- [ ] No UI code path can render an absolute joint angle
- [ ] The same movement filmed from two camera angles produces ROM percentages within 5% of each other
- [ ] Absolute angles are present in traces for diagnosis

## Notes
This constraint is a product decision as much as a technical one, and it is one of the honesty-page entries. Every competitor shows degrees; the degrees are not that accurate.
