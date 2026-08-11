# W8-02 · Volume ledger

**Wave:** 8 — Tim Method Engine
**Status:** open
**Depends on:** W8-01, W7-01
**Spec:** §11.2

## Goal
Rolling weekly hard sets per muscle group, with honest uncertainty at the top end.

## Why
Volume is the one training variable with a clear, quantified dose-response — roughly 0.24% extra size per fractional set at a dataset mean of 12.25 sets/week.

## Do
- [ ] Rolling 7-day count per muscle, direct sets at 1.0 and indirect at 0.5
- [ ] Working band **12–20 sets per muscle per week**
- [ ] Per-session cap around **11 fractional sets per muscle**, past which added sets stop paying off
- [ ] Above 25 sets/week, warn that the evidence thins rather than claiming a ceiling
- [ ] A set only counts as "hard" if it reached the VL cutoff or was taken within the RIR band
- [ ] Per-muscle weekly view

## Done when
- [ ] Ledger matches hand-computed values on a synthetic week
- [ ] The above-25 warning states uncertainty, not a prohibition
- [ ] Warm-up sets are excluded and that exclusion is visible

## Notes
Two corrections that belong in the UI copy, because both are widely misreported. The famous <5 / 5–9 / 10+ categorical split was **not significant** (p = 0.074) — only the continuous slope held. And the study behind "5–10 sets is enough, more is worse" was **retracted in June 2020** and still circulates uncredited.
