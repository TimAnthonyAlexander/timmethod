# W6-08 · Thermal degradation ladder

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W6-02, W6-05
**Spec:** §16

## Goal
Degrade deliberately under thermal pressure instead of being throttled arbitrarily.

## Why
Sustained camera plus ML is among the most thermally hostile things a phone does. For a 45-minute session, hitting `.serious` is the normal case, not the exception.

## Do
- [ ] Observe `ProcessInfo.thermalState` and `thermalStateDidChangeNotification` from day one
- [ ] `.nominal` → full pipeline
- [ ] `.fair` → pose every 4th frame; plate detection unchanged
- [ ] `.serious` → 30fps capture; pose off unless the exercise requires it; **plate track alone still counts and still measures velocity**
- [ ] `.critical` → counting continues on plate track; preview dims; overlay off
- [ ] Log every transition into the session record
- [ ] `isIdleTimerDisabled` set on session start and **always** cleared on end
- [ ] Prefer `.cpuAndNeuralEngine` for any Core ML compute units

## Done when
- [ ] A 45-minute session on the dev device completes without losing the rep count
- [ ] Every thermal transition is logged
- [ ] The idle timer is verifiably restored after a force-quit mid-session

## Notes
This is the direct payoff of the two-track architecture: the cheap track is also the accurate one for loaded work, so throttling costs the skeleton overlay and form flags, never the count.
