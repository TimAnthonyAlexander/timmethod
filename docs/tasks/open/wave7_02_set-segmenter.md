# W7-02 · Set and rest segmentation

**Wave:** 7 — Sessions & Persistence
**Status:** open
**Depends on:** W3-06
**Spec:** §10

## Goal
Detect set start and end automatically. Zero manual input during a workout.

## Why
No pose-only published approach to "set versus walking around and racking a bar" exists. This is engineering judgment built on a signal already being computed.

## Do
- [ ] Run a periodicity estimate continuously over the `RepSignal` — a poor rep counter but a good "is this periodic right now" detector, which is a much easier question
- [ ] A **set** is a maximal window where periodicity strength exceeds threshold, the posture gate holds, and subject-lock confidence holds
- [ ] Set ends when periodicity collapses for >4s or the posture gate opens
- [ ] Rest timing starts on set end and is a first-class measurement — §11.4 needs it
- [ ] Add short-time energy as a complementary boundary cue if periodicity alone proves noisy
- [ ] Manual override always available; automatic is the default, not the only option

## Done when
- [ ] Set-boundary F1 ≥ 0.95 on fixtures containing full sessions with rest
- [ ] Racking a bar does not extend the set
- [ ] Rest durations match hand annotation within 2s

## Notes
Long-clip fixtures are needed here, not single-set clips. Most datasets ship per-set videos, so this may need self-recorded session footage — a legitimate use of the small personal video budget.
