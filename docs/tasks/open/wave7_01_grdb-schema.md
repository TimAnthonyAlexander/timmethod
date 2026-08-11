# W7-01 · GRDB schema and migrations

**Wave:** 7 — Sessions & Persistence
**Status:** open
**Depends on:** W1-01
**Spec:** §12, §13

## Goal
The §12 data model on disk, with migrations from the first version.

## Why
GRDB and not SwiftData: the workload is heavy aggregation over sets and reps, and `#Predicate` cannot push aggregates down to SQL — no `GROUP BY`, no sum, no average at the storage layer.

## Do
- [ ] Tables: `session`, `work_set`, `rep`, `exercise`, `movement_template`, `thermal_event`
- [ ] GRDB migrations registered from v1, never ad-hoc schema edits
- [ ] Indices on the queries the volume ledger actually runs (by muscle, by week, by exercise)
- [ ] Store `signalTrace` compressed — every rep carries one, and that adds up
- [ ] Codable record types with tests round-tripping every field
- [ ] Store `scaleSource` per set, so a later reader knows how much to trust the metres

## Done when
- [ ] Migrations apply from empty and are idempotent
- [ ] A synthetic 200-session database queries the weekly volume ledger in under 50 ms
- [ ] Every §12 field persists and round-trips

## Notes
Point-Free's SQLiteData sits on GRDB and adds CloudKit sync including sharing, if that is ever wanted. Designing the schema on plain GRDB now keeps that path open without paying for it.
