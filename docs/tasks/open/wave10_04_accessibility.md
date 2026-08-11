# W10-04 · Accessibility

**Wave:** 10 — Ship Readiness
**Status:** open
**Depends on:** W6-06, W7-05
**Spec:** §14

## Goal
Usable with Dynamic Type, VoiceOver and Reduce Motion.

## Why
Full-featured includes this. It is also cheap when done alongside the UI rather than after it.

## Do
- [ ] Dynamic Type through the largest accessibility sizes, with the live instrument degrading sensibly rather than clipping
- [ ] VoiceOver labels on every control; the live instrument announces rep count and VL state meaningfully
- [ ] Reduce Motion honoured in the overlay and charts
- [ ] Contrast verified against both bright and dark camera feeds, not just a flat background
- [ ] Touch targets at 44pt minimum, sized for sweaty hands mid-session

## Done when
- [ ] Accessibility Inspector reports no issues
- [ ] The app is navigable end to end with VoiceOver
- [ ] Layout holds at the largest Dynamic Type size

## Notes
The live instrument is the hard case: it is deliberately minimal and largely non-textual. Its VoiceOver representation needs designing, not auto-generating.
