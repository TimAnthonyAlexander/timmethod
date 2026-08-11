# W1-07 · RepSignal type

**Wave:** 1 — Foundations & Harness
**Status:** done
**Depends on:** W1-01
**Spec:** §6

## Goal
The single abstraction both trackers produce and the counter consumes.

## Why
One counter, two signal sources. This type is what makes that true instead of aspirational.

## Do
- [ ] `struct RepSignal` with a ring buffer of `(t, x, confidence)` samples
- [ ] `x` in metres along the working axis, positive away from the ground
- [ ] `enum ScaleSource { plateDiameter, lidarBodyHeight, referenceHeight, torsoRelative }`
- [ ] Ring buffer sized for the longest plausible set (say 180s at 60Hz) with O(1) append
- [ ] Downsampled trace export for the harness and for `Rep.signalTrace`

## Done when
- [ ] Unit tested for wraparound, ordering, and trace export fidelity
- [ ] A synthetic sine wave round-trips through it without distortion

## Notes
`ScaleSource` is not cosmetic. `referenceHeight` means Apple substituted a fixed 1.8 m body height, so every absolute metre downstream carries an error proportional to (true height − 1.8)/1.8. The UI must be able to tell the difference.
