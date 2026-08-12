# W2-05 · Plate and equipment configuration

**Wave:** 2 — Track A: Plate Tracking
**Status:** done
**Depends on:** W1-01
**Spec:** §8

## Goal
Know the real-world diameter of whatever is being tracked.

## Why
Scale is only as good as the assumed diameter. A wrong plate size silently scales every velocity and every ROM measurement.

## Do
- [ ] Built-in diameters: Olympic and bumper plates at 450 mm
- [ ] Standard 1-inch plates: user picks from a list, since these vary
- [ ] Dumbbells: user enters end-cap diameter once per pair
- [ ] Store per exercise on `Exercise.plateDiameterMm`
- [ ] A one-time measure-against-a-reference flow for anything unlisted

## Done when
- [ ] Changing the configured diameter changes computed velocity proportionally, as verified by a test
- [ ] An exercise with no configured diameter refuses Track A rather than guessing 450 mm

## Notes
Refusing is the right behaviour. A silently wrong scale produces confident, plausible, wrong numbers — the worst failure mode this app has.
