# W8-01 · Exercise catalog

**Wave:** 8 — Tim Method Engine
**Status:** open
**Depends on:** W7-01
**Spec:** §2, §12

## Goal
The v1 exercises, with the metadata the training layer needs.

## Why
The volume ledger cannot count sets per muscle without knowing which muscles a movement trains, and which count as secondary.

## Do
- [ ] The ten v1 loaded movements: back squat, front squat, bench press, overhead press, barbell row, Romanian deadlift, deadlift, dumbbell curl, dumbbell shoulder press, dumbbell row
- [ ] The five bodyweight movements: push-up, pull-up, chin-up, dip, bodyweight squat
- [ ] Per exercise: equipment, plate diameter, primary and secondary muscles, preferred track, default rep range, default VL target
- [ ] Secondary muscles count **0.5** toward the volume ledger
- [ ] Concentric direction per exercise (needed by W4-01)

## Done when
- [ ] All fifteen load with complete metadata
- [ ] Muscle assignments are reviewed once against a standard reference rather than guessed

## Notes
Fractional set counting comes from the 2026 meta-regression, which found the empirical weight for indirect sets closer to 0.32 for hypertrophy and 0.16 for strength. 0.5 is the round number that paper itself uses; note the discrepancy in the honesty page rather than pretending 0.5 is measured.
