# W5-04 · Subject lock

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-02
**Spec:** §7.1

## Goal
Track one person and ignore everyone else in the gym.

## Why
Multi-person frames are out of scope as a feature but unavoidable as a reality. Centroid-based locking onto the largest or nearest person is the documented working fix.

## Do
- [ ] Lock onto the largest/nearest detected person on set start
- [ ] Maintain the lock across frames by centroid proximity
- [ ] Re-acquire deliberately after a loss, preferring the previously locked centroid region
- [ ] Never silently switch subjects mid-set — a switch ends the set

## Done when
- [ ] A fixture with a bystander walking behind the lifter counts correctly
- [ ] A subject switch is detected and ends the set rather than blending two people's reps

## Notes
Apple Vision 3D is single-person, which does most of this for free but gives no control over *which* person. Verify what it picks when two people are in frame.
