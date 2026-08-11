# W9-02 · Cycle normalization

**Wave:** 9 — Few-shot Enrollment
**Status:** open
**Depends on:** W9-01
**Spec:** §9.3

## Goal
Resample a rep cycle to a fixed-length, scale-invariant representation.

## Why
DTW comparison needs a canonical form. Reps vary in duration and in absolute amplitude, and neither should affect identity.

## Do
- [ ] Resample each cycle to a fixed sample count
- [ ] Normalize amplitude so a heavy set and a light set of the same movement match
- [ ] Retain the landmark trajectory alongside the 1D signal — the 1D form is often not discriminative enough between similar movements
- [ ] Store as `MovementTemplate` per §12

## Done when
- [ ] Two reps of the same movement at different speeds normalize to near-identical curves
- [ ] Two genuinely different movements do not

## Notes
Squat and deadlift have similar 1D vertical signals and very different landmark trajectories. That is precisely why the trajectory is retained.
