# W1-06 · Acquire and convert datasets

**Wave:** 1 — Foundations & Harness
**Status:** open
**Depends on:** W1-04
**Spec:** §15.1

## Goal
A populated `fixtures/` directory covering barbell, dumbbell and bodyweight movements.

## Why
There is no substitute. The counter cannot be tuned against nothing, and the personal-video budget is small by decision.

## Do
- [ ] Submit the **FLEX** academic request form — 20 weight-loaded exercises evenly split barbell/dumbbell, 38 subjects, 5 camera angles, 7,500+ recordings. This is the primary source and the request has lead time, so do it first
- [ ] Download **MM-Fit** (open, 5 dumbbell exercises, rep labels included)
- [ ] Download **InfiniteRep** (CC BY 4.0, 1,000 synthetic bodyweight clips)
- [ ] Download **RepCount-A** for counting stress-tests; record that no explicit licence was found
- [ ] Request **Fitness-AQA** for form-flag validation later
- [ ] Conversion script per dataset → fixture format, preserving each source's own rep annotations as ground truth
- [ ] Record licence per fixture (see W1-04)

## Done when
- [ ] At least 200 fixtures load and validate
- [ ] Barbell, dumbbell and bodyweight are all represented
- [ ] `fixtures/LICENCES.md` states what may and may not be used commercially

## Notes
FLEX is CC BY-NC-SA and gated. Correct for a personal build, a blocker on ship. Start the request early — it is the long pole in this wave.
