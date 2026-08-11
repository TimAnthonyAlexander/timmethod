# W9-04 · Enrollment interface

**Wave:** 9 — Few-shot Enrollment
**Status:** open
**Depends on:** W9-01, W6-04
**Spec:** §9.3

## Goal
Make adding a movement feel like a feature, not a configuration chore.

## Why
This is how the app reaches thirty-plus exercises without shipping thirty state machines. It should be inviting enough that it actually gets used.

## Do
- [ ] Entry point from the exercise picker: "teach a new movement"
- [ ] Guided flow with live feedback during the demonstration
- [ ] Confirmation screen showing the captured cycles overlaid, so the user can see consistency
- [ ] Edit and delete for enrolled movements
- [ ] Muscle assignment during enrollment, since the volume ledger needs it

## Done when
- [ ] End-to-end enrollment of a novel movement works on device in one sitting
- [ ] The overlay of captured cycles is legible and actually useful for judging consistency
- [ ] Deleting a movement handles historical sets that reference it

## Notes
Muscle assignment is easy to forget and breaks the ledger silently. Make it a required step, not an optional one.
