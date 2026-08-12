# W1-06 · Build the fixture set

**Wave:** 1 — Foundations & Harness
**Status:** done
**Depends on:** W1-04
**Spec:** §15.1

## Goal
A populated `fixtures/` directory of **real footage with real rep annotations**,
built from sources that need no request form and no self-recording.

## Why
There is no substitute. The counter cannot be tuned against nothing, and it
certainly cannot be tuned against synthetic clips — those only ever measure how
well the generator was reverse-engineered.

## Do

**No request forms, no data-use agreements, and no filming.** FLEX and
Fitness-AQA are gated and non-commercial, so they are out permanently. Recording
our own is also out: it is a day of work to produce one subject in one gym,
which is worse coverage than what is already downloadable.

- [ ] **Countix** — the primary source. 8,375 clips derived from Kinetics, each
      with a rep `count` and `repetition_start`/`repetition_end` in seconds. The
      CSVs are ungated. Relevant classes, counted from the CSVs:
      `bench pressing` 92, `squat` 96, `pull ups` 142, `push up` 154,
      plus `exercising arm` 148 and `rope pushdown` 180 as adjacent cases.
      Videos come down with `yt-dlp` against the YouTube id, trimmed to the
      `kinetics_start`/`kinetics_end` window.
- [ ] **RepCount-A** — 1,041 fitness videos, 19,280 rep annotations, ungated
      download. Counting stress-test and a second opinion on the classes above.
- [ ] **MM-Fit** — open download, 10 exercises including 5 dumbbell, rep
      labelled. Dumbbell coverage.
- [ ] **InfiniteRep** — CC BY 4.0 and commercially clean, 1,000 synthetic
      bodyweight clips with varied avatars and lighting. Bodyweight and the
      lighting sweep.
- [ ] One conversion script per source into the W1-04 fixture format, preserving
      each source's own annotations as ground truth. Never re-label by hand what
      the source already labelled.
- [ ] Record licence per fixture. Videos stay gitignored; sidecars are tracked.

**Expect attrition.** Kinetics is a list of YouTube ids and some are deleted or
region-blocked. Record how many resolved out of how many were attempted, per
class, so the corpus size is a measured number rather than a hoped-for one.

**Plate diameter on found footage.** We cannot know it. Assume 450 mm on
barbell clips, which is right for Olympic and bumper plates and therefore right
for most gym and competition footage, and mark it as assumed in the sidecar.
This is safe for counting and unsafe for velocity: the ratchet establishes range
from the lifter's own first three reps, so a wrong scale cancels out of the count
entirely, while it scales every m/s figure linearly. So count metrics from this
corpus are trustworthy and velocity metrics from it are not. §15.2's velocity
target cannot be scored against found footage at all — it needs a clip with a
known criterion, which this corpus does not contain.

## Done when
- [ ] At least 200 fixtures load and validate
- [ ] Barbell, dumbbell and bodyweight are all represented
- [ ] `fixtures/MANIFEST.md` records per source: attempted, resolved, licence,
      and what it may be used for
- [ ] The eval CLI runs the full set end to end and produces a report

## Notes
This corpus scores **counting**, which is what waves 2 and 3 are for and what
W2-06 and W3-06 gate on. It does not score velocity, and it will not contain the
adversarial cases §15.1 lists — a baggy hoodie, a rack upright crossing the bar,
a set taken to genuine failure so ROM visibly collapses. Those remain owed, and
the to-failure clip in particular is the only real test of the W3-04 ratchet
(open question 6). Do not let a good MAE on found footage imply those were
covered.
