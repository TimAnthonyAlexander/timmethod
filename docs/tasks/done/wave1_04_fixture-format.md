# W1-04 · Fixture format and loader

**Wave:** 1 — Foundations & Harness
**Status:** done
**Depends on:** W1-01
**Spec:** §15

## Goal
A clip plus a sidecar JSON of ground truth, and a loader that reads a directory of them.

## Why
The harness needs a stable contract before there is anything to score. Changing this format later invalidates every recorded ground truth.

## Do
- [ ] Define `fixture.json`: exercise id, equipment, plate diameter mm, true rep count, true partial count, camera position, lighting note, source dataset, optional per-rep timestamps
- [ ] Loader that walks a fixtures directory and pairs `.mov` with `.json`
- [ ] Validation with clear errors on missing or malformed sidecars
- [ ] A `fixtures/README.md` documenting the schema and how to add a clip

## Done when
- [ ] Three hand-made fixtures load and validate
- [ ] A malformed sidecar produces a useful error, not a crash

## Notes
Include a `licence` field per fixture. FLEX and Fitness-AQA are non-commercial; that has to be queryable so the set can be rebuilt if this ever ships (open question 9).
