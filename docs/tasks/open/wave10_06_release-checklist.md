# W10-06 · Release checklist

**Wave:** 10 — Ship Readiness
**Status:** open
**Depends on:** W10-01, W10-02, W10-03, W10-04, W10-05
**Spec:** §17, §19

## Goal
Everything that has to be true before this is considered done, whether or not it ever reaches the store.

## Why
"Personal deployment" is not a reason to leave loose ends. It is a reason there is no external deadline forcing them closed.

## Do
- [ ] Full harness run green against §15.2 targets, recorded with a date and a commit hash
- [ ] A 45-minute real session on device with no crash, no count loss, and thermal transitions logged
- [ ] Battery drain over that session measured and recorded
- [ ] Every open question in §19 either closed or explicitly re-scoped with a reason
- [ ] **Licence audit**: FLEX and Fitness-AQA are non-commercial. If distribution is ever on the table, the fixture set must be rebuilt from InfiniteRep, MM-Fit and own clips. Record the current status either way
- [ ] Spec updated so §4.1, §19 and §15.2 reflect measured reality rather than the original reasoning
- [ ] Crash-free install → onboarding → first session on a wiped device

## Done when
- [ ] Every box above is ticked with evidence, not assertion
- [ ] The spec no longer contains provisional reasoning that has since been settled by data

## Notes
Closing open question 9 (the licence swap) is the one item that changes depending on where this lands. Record the decision explicitly rather than leaving it implied by inaction.
