# W7-06 · HealthKit workout write

**Wave:** 7 — Sessions & Persistence
**Status:** open
**Depends on:** W7-03
**Spec:** §13

## Goal
Sessions land in Fitness and contribute to the Move ring.

## Why
It is where workouts belong on iOS, and it costs little.

## Do
- [ ] `HKWorkoutSession` — now first-class on iOS, not watchOS-only — with `HKLiveWorkoutBuilder`
- [ ] Write duration and active energy; `.traditionalStrengthTraining` activity type
- [ ] Rep detail as custom metadata, understanding Apple's UI will not surface it
- [ ] Crash recovery via `shouldHandleActiveWorkoutRecovery` and `recoverActiveWorkoutSession`
- [ ] Authorization flow with a denied path that does not break the app
- [ ] Guideline 5.1.3(ii): never write false data

## Done when
- [ ] A session appears in Fitness and contributes to Move
- [ ] Denying HealthKit leaves the app fully functional
- [ ] A force-quit mid-workout recovers the session

## Notes
There is no HealthKit quantity type for repetitions — none of Apple's identifiers cover rep counts. Reps stay in GRDB. Do not contort the schema trying to make HealthKit the source of truth.
