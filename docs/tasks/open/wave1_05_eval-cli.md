# W1-05 · Evaluation CLI

**Wave:** 1 — Foundations & Harness
**Status:** open
**Depends on:** W1-03, W1-04
**Spec:** §15, §15.2

## Goal
`timmethod-eval --fixtures ./fixtures --provider X --report out.json` scores the whole set and prints a summary.

## Why
This is milestone zero of the whole project. It is how every subsequent tuning decision gets made.

## Do
- [ ] Argument parsing: `--fixtures`, `--provider`, `--report`, `--filter <exercise>`, `--verbose`
- [ ] Per-clip: predicted count, true count, delta, partials, false positives, false negatives
- [ ] Aggregate: MAE, off-by-one accuracy, FP/session, per-exercise breakdown
- [ ] JSON report plus a readable terminal table
- [ ] Non-zero exit when aggregate falls below the §15.2 floor, so it works as a regression gate
- [ ] Dump the `signalTrace` for any clip whose count is wrong, to `out/traces/`

## Done when
- [ ] Runs end to end against a stub counter and produces both outputs
- [ ] Wrong-count clips leave a trace file behind for inspection

## Notes
The trace dump is the difference between "the count was wrong" and "the count was wrong because the third rep only swept 62% amplitude." Build it now, not after the first confusing failure.
