# W3-07 · Track A pipeline integration

**Wave:** 3 — Rep Counter
**Status:** done
**Depends on:** W2-04, W3-04, W3-05
**Spec:** §3, §15

> Added 2026-08-12, not in the original 63. Waves 2 and 3 built nine components
> in isolation, each unit-tested against synthetic input. Nothing assembles them.
> Both W2-06 and W3-06 assume a working end-to-end pipeline and neither can run
> without one, so the assembly is real work that belongs to somebody.

## Goal
One `RepCounting` conformer that runs the real Track A pipeline end to end, and
replaces `StubRepCounter` in the eval harness.

## Why
Nine components that each pass their own tests do not add up to a counter. Every
interface between them is untested — and interfaces are where isolated units
actually fail. Finding that out now, against synthetic clips, is much cheaper
than finding out on the day the real footage lands.

## Do
- [ ] Assemble: `ReplayFrameSource` → `PlateDetector` → `PlateTracker` →
      `MetricScale` → `MotionAxis` → `RepSignal` → `SignalConditioning` →
      `ZeroCrossCounter` → `AmplitudeGate`, with `PostureGate` gating and
      `RangeCalibration` driving `A_min`
- [ ] Wire `SetCalibration` into `AmplitudeGate.Configuration` — W3-04 left this
      deliberately, since it was told not to touch the gate
- [ ] Replace `StubRepCounter` in the harness with the real one, keeping the stub
      for tests that want a predictable counter
- [ ] Every rejected candidate's reason reaches the trace dump, so a wrong count
      on a real clip is diagnosable without a rebuild
- [ ] Plate diameter comes from the fixture sidecar; a fixture without one gets
      no Track A rather than an assumed 450 mm

## Done when
- [ ] `timmethod-eval` runs the real pipeline against the three example fixtures
      and produces a report without crashing
- [ ] A synthetic clip with a plate moving in a known number of cycles counts
      that number end to end, through every real component
- [ ] Rejection reasons from the gate appear in `out/traces/`
- [ ] The gate still fails on the example fixtures, honestly — they are
      solid-colour placeholders with no plate in them, so zero is the correct
      answer and a non-zero count would mean something is wrong

## Notes
Expect interface friction. `MotionAxis` consumes tracker output, `AmplitudeGate`
wants posture observations spanning a candidate's window, and `RangeCalibration`
needs accepted reps before it can set the threshold that decides acceptance.
Those seams were each designed from one side only.

Do not tune anything here. Tuning against synthetic clips would fit the
generator, not the lift. Parameters get tuned at W3-06 against real footage.
