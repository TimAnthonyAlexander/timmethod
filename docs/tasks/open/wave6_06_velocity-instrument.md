# W6-06 · The velocity instrument

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W4-03, W6-04
**Spec:** §14.1

## Goal
The one thing worth looking at during a set: how much velocity is left before it should stop.

## Why
Rep count is not the interesting number during a set — you know roughly where you are. Whether to do another rep is the decision the app exists to inform.

## Do
- [ ] A single bar whose **length** encodes remaining velocity budget before the block's VL cutoff
- [ ] Bone-coloured throughout; saturates to oxide only on crossing the cutoff
- [ ] Rep count large but visually secondary
- [ ] RIR band shown as a band, never an integer
- [ ] ROM percentage does not appear live — it belongs in the set summary
- [ ] Readable at 2–3 m, which is the actual viewing distance. Test it there, not at arm's length

## Done when
- [ ] Legible from 3 m on the dev device
- [ ] No traffic-light gradient, no second accent colour anywhere
- [ ] Bar updates within one rep of the underlying VL change

## Notes
Test at real distance early. A layout that reads perfectly in your hand can be useless propped against a wall across the room, and that is the only viewing position this app has.
