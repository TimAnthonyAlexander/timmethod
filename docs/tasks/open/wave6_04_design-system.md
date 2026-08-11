# W6-04 · Design system

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W1-01
**Spec:** §14.1

## Goal
Tokens, type scale and iconography, defined once.

## Why
The screen is an instrument, not a dashboard. That only holds if the constraint is encoded somewhere rather than re-decided per screen.

## Do
- [ ] Colour tokens, exactly three: ground `#121110` warm near-black, type `#F2EDE4` bone, accent `#B4472E` oxide
- [ ] The accent has **exactly one meaning: stop the set.** No other use anywhere
- [ ] Type: SF Pro, two weights — bold for numerals, regular for everything else
- [ ] SF Symbols only, consistent stroke weight and optical alignment
- [ ] No emoji, no decorative status dots, no accent bars, no gradients
- [ ] Dark-first, since the app lives over live video; verify contrast over bright and dark camera feeds
- [ ] Tested at 375pt width even though the dev device is a Pro Max

## Done when
- [ ] A tokens file exists and no view hardcodes a colour
- [ ] A lint or review check catches accent misuse
- [ ] Legibility verified over both a bright gym and a dim home room

## Notes
The velocity bar carries information through length, never hue. One colour, one meaning. If a second accent starts to feel necessary, the screen is doing too much.
