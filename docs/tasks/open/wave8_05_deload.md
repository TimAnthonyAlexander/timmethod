# W8-05 · Fatigue detection and deload prompt

**Wave:** 8 — Tim Method Engine
**Status:** open
**Depends on:** W8-04
**Spec:** §11.6

## Goal
Notice accumulated fatigue from velocity, before it becomes a stall.

## Why
First-rep velocity at a fixed load is a direct fatigue readout that needs no questionnaire.

## Do
- [ ] Flag when first-rep velocity at the same load drops ≥10% across two consecutive sessions
- [ ] Also flag a sustained rise in session-level VL at matched load and reps
- [ ] Suggest a deload; do not impose one
- [ ] Show the velocity trend that triggered it, so the suggestion is inspectable
- [ ] Dismissible, and dismissals are remembered

## Done when
- [ ] Synthetic declining-velocity history triggers the flag at the right session
- [ ] Normal session-to-session noise does not trigger it
- [ ] The triggering chart is one tap away

## Notes
There is essentially no 2025 literature on deloads — zero PubMed hits for the search. This is a reasoned heuristic on a measured signal, and the honesty page should say exactly that.
