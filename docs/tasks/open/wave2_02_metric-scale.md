# W2-02 · Metric scale from plate diameter

**Wave:** 2 — Track A: Plate Tracking
**Status:** open
**Depends on:** W2-01
**Spec:** §8, §6

## Goal
Convert pixels to metres, every frame, from the fitted major axis.

## Why
This is the quiet payoff of plate tracking. A known-diameter object hands you absolute scale on any iPhone with no depth sensor, which is the problem `bodyHeight` was going to solve badly.

## Do
- [ ] `pixels_per_metre = major_axis_px / plate_diameter_m`
- [ ] Recompute every frame so the lifter drifting toward or away from the camera does not corrupt the scale
- [ ] Smooth the scale estimate over a short window; it should change slowly even though the source is per-frame
- [ ] Emit `ScaleSource.plateDiameter` on the resulting `RepSignal`
- [ ] Sanity bounds: reject a scale implying the subject is under 0.5 m or over 8 m away

## Done when
- [ ] A clip with a known subject distance recovers that distance to within 5%
- [ ] Scale remains stable across a set where the lifter shifts position

## Notes
On the Pro Max, LiDAR could cross-check this once at setup. Worth doing as a validation experiment, not as a runtime dependency — depth is not a dependable 30fps stream and Apple warns it throttles video frame rate.
