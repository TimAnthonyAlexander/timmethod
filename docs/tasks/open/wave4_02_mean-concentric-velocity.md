# W4-02 · Mean concentric velocity

**Wave:** 4 — Velocity
**Status:** open
**Depends on:** W4-01, W2-02
**Spec:** §8.1, §15.2

## Goal
Metres per second, per rep, accurate enough to be worth acting on.

## Why
This is the measurement that replaces self-reported RPE. If it is not accurate, the whole training layer is theatre.

## Do
- [ ] Mean concentric velocity = concentric displacement (m) / concentric duration (s)
- [ ] Also compute peak velocity
- [ ] Return `nil` rather than a number when `ScaleSource` is `torsoRelative` — no metric scale means no velocity
- [ ] Flag reps computed under `referenceHeight` scale as lower confidence

## Done when
- [ ] RMSE ≤ 0.05 m/s against FLEX reference velocity where available
- [ ] Velocity is nil, not zero or fabricated, on unscaled signals

## Notes
The target is set against what has been achieved: 0.01–0.04 m/s RMSE from a phone camera versus Vicon, validated in PLOS ONE 2024. It is a real bar and it has been cleared before. 60fps capture is deliberate here — 25Hz is sufficient for the physical signal, the extra margin is against CV detection jitter.
