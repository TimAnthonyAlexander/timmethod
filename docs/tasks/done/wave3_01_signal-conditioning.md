# W3-01 · Signal conditioning

**Wave:** 3 — Rep Counter
**Status:** done
**Depends on:** W1-07
**Spec:** §4.1, §7.2

## Goal
Detrend the signal and produce a clean derivative, with smoothing off by default.

## Why
Everything the counter does keys off zero crossings of velocity. A drifting baseline or a noisy derivative destroys that directly.

## Do
- [ ] Rolling-median detrend, ~3s window, to remove slow drift (lifter shifting, camera settling)
- [ ] Central-difference derivative with the real inter-sample dt, not an assumed frame period
- [ ] One Euro filter available on the **1D signal**, behind a flag, **default off**
- [ ] A `--jitter-report` mode in the CLI that measures static-subject noise so the smoothing decision is made from data

## Done when
- [ ] ~~Static-subject jitter is quantified for each backend and recorded~~
      **Deferred to W5-08.** `--jitter-report` works and produces real numbers
      for any signal handed to it, but there is no second backend to compare
      against until `PoseProvider` exists, and no real static-hold footage until
      W1-06. The bake-off is where this number gets filled in.
- [ ] Derivative of a synthetic sine matches analytic within tolerance
- [ ] The default path applies no additional smoothing

## Notes
Do not add per-landmark smoothing. MediaPipe already One-Euro-filters internally in stream mode (2D: min_cutoff 0.05 / beta 80; world: 0.1 / 40), so a second filter double-smooths and stacks lag. Whether Apple Vision filters internally is undocumented — that is exactly what `--jitter-report` answers. If smoothing is needed at all, one filter on one scalar beats 33 landmarks × 3 coordinates: less lag, one parameter pair, and it is the only signal the counter reads.
