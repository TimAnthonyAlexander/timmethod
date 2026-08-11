# W9-01 · Template capture

**Wave:** 9 — Few-shot Enrollment
**Status:** open
**Depends on:** W3-06, W5-05
**Spec:** §9.3

## Goal
Demonstrate two or three reps of a new movement and have the system record a template.

## Why
A supervised classifier is ruled out by the data budget — Create ML's action classifier needs roughly 50 videos per class, and thirty exercises would be 1,500 recordings. Few-shot enrollment is the only path, and it is also the better feature.

## Do
- [ ] Guided capture: name the exercise, pick equipment, set plate diameter if loaded, then perform 2–3 reps
- [ ] Use the existing counter to segment the demonstration into cycles — do not build a second segmenter
- [ ] Reject a demonstration whose cycles disagree too much, and ask for another
- [ ] Store the raw cycles alongside the derived template, so templates can be rebuilt if the algorithm changes
- [ ] Let the user add more examples later to strengthen an existing template

## Done when
- [ ] A novel movement enrolls in under a minute
- [ ] An inconsistent demonstration is rejected with a useful message
- [ ] Templates survive an algorithm change via rebuild from raw cycles

## Notes
Storing raw cycles is the difference between a template set you can improve and one you have to re-record. Cheap insurance.
