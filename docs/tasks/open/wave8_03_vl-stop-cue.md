# W8-03 · Velocity-loss stop cue

**Wave:** 8 — Tim Method Engine
**Status:** open
**Depends on:** W4-04, W6-06
**Spec:** §11.1

## Goal
Tell the lifter when to rack it, from measured velocity rather than a self-report prompt.

## Why
This is the product thesis in one feature. RPE-based autoregulation scored SMD 0.12, non-significant, in the 2026 network meta-analysis, ranking last of five methods for jump power. Velocity-based scored 0.41.

## Do
- [ ] Default cutoff **VL20**, per block, per exercise
- [ ] A hypertrophy-biased block may raise it toward VL30, as a visible setting with the tradeoff stated
- [ ] The instrument (W6-06) saturates to oxide on crossing
- [ ] Record whether the lifter actually stopped, so the setting can be evaluated against behaviour
- [ ] **Never prompt for RPE.** No code path asks how the set felt

## Done when
- [ ] Cutoff fires within one rep of the computed threshold
- [ ] Changing the block cutoff visibly changes stop behaviour
- [ ] A repo-wide search confirms no RPE input exists anywhere

## Notes
VL20 is the defensible default. The 2020 four-arm study (0/10/20/40% VL, n=64) found no between-group strength difference, more hypertrophy at VL20 and VL40 than at VL0/VL10, and that VL40 alone significantly slowed activation delay and cut early rate of force development. Excess velocity loss buys hypertrophy at a measurable neuromuscular cost.
