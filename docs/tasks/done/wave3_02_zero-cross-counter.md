# W3-02 · Zero-crossing counter

**Wave:** 3 — Rep Counter
**Status:** done
**Depends on:** W3-01
**Spec:** §7.2

## Goal
Detect candidate reps as sign-alternating velocity zero crossings forming peak → valley → peak.

## Why
This is the shipped pattern, not a novel one: project to 1D, zero-cross, merge crossings below a magnitude threshold. It is what NEX Team patented and shipped in HomeCourt.

## Do
- [ ] Track sign changes in the velocity signal
- [ ] Assemble candidate cycles as peak → valley → peak
- [ ] Merge crossing pairs whose magnitude difference is below threshold (the debounce)
- [ ] Emit candidates to the gate (W3-03) rather than counting directly
- [ ] Count on **return to start**, never on reaching the bottom

## Done when
- [ ] A synthetic 10-cycle sine yields exactly 10 candidates
- [ ] A sine with an injected noise spike yields 10, not 11
- [ ] An abandoned half-cycle yields 0

## Notes
Keep this dumb and pure. All the judgment lives in the gate. Separating them is what makes both testable.
