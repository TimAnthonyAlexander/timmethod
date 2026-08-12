# W1-06 · Build the fixture set

**Wave:** 1 — Foundations & Harness
**Status:** open
**Depends on:** W1-04
**Spec:** §15.1

## Goal
A populated `fixtures/` directory covering barbell, dumbbell and bodyweight
movements, built entirely from sources that need no request form.

## Why
There is no substitute. The counter cannot be tuned against nothing.

## Do

**No academic request forms, no data-use agreements.** FLEX and Fitness-AQA are
out permanently — both are gated behind a form, and both are non-commercial
anyway, so they were always going to be torn out before ship (§19 open question
9). Removing them now costs less than removing them later.

- [ ] **Self-record the loaded barbell set. This is the primary source, not a
      fallback.** FLEX's advantage was 5 camera angles across 38 subjects; its
      disadvantage was that none of those subjects is you, in your gym, under
      your lighting, with your rack. One subject filmed properly beats 38 filmed
      elsewhere for a single-user app. The matrix that matters:
      10 v1 exercises × 3 camera angles (perpendicular, 30° off, 45° off)
      × 2 conditions (fresh, fatigued) ≈ 60 clips, one working set each.
      Roughly one session of filming plus one of labelling.
- [ ] **MM-Fit** — open download, no form, 10 exercises with 5 dumbbell,
      rep-labelled. Covers the dumbbell track.
- [ ] **InfiniteRep** — CC BY 4.0, commercially clean, 1,000 synthetic
      bodyweight clips with varied avatars and lighting. Covers the bodyweight
      track and the lighting sweep.
- [ ] **RepCount-A** and **QUVA Repetition** — counting stress-tests only. QUVA
      is mostly non-gym (chopping, brushing hair, basketball) and RepCount-A has
      no explicit licence; neither is scope-representative, both are useful for
      finding where a counter falls over. Record the licence gap.
- [ ] The clips only you can provide, from §15.1: baggy hoodie, your actual gym
      lighting, deliberate partial reps, a set to genuine failure so ROM visibly
      collapses, and one set where you walk out of frame mid-set and come back.
- [ ] Conversion script per source → fixture format, preserving each source's
      own rep annotations as ground truth.
- [ ] Record licence per fixture (W1-04 makes this a queryable enum).

**Rep-count ground truth.** Label by keyboard, not by mouse. A published user
study puts full start/end boundary annotation at roughly 1–5× real time
depending on action density; a keyboard event logger sits at the fast end,
a bounding-box tool at 7–18× for the same clips. Mark rep boundaries with a
single-key toggle against a frame-stepped video. Use `mediaTime` from
`requestVideoFrameCallback`, never `currentTime` — `currentTime` is not
frame-snapped and drifts by up to a full frame period, which at 60 fps is 16 ms
of error injected into every boundary. Re-encode clips to constant frame rate
first or frame indices will not be reliable.

**Velocity ground truth, without buying a linear position transducer.** Film a
subset at 240 fps on the iPhone and hand-digitise the two concentric endpoints.
Mean concentric velocity is just displacement over duration, so only two marks
per rep are needed. Error budget: endpoint position to ±5 mm against a 450 mm
plate, timing to ±1/240 s, over a typical 0.5 m concentric lasting 0.6 s →
roughly ±0.01 m/s. That is five times tighter than the ≤ 0.05 m/s target in
§15.2 and needs no hardware. Do this for one set per exercise, not for
everything.

## Done when
- [ ] At least 200 fixtures load and validate
- [ ] Barbell, dumbbell and bodyweight are all represented
- [ ] At least 3 camera angles represented on the barbell clips
- [ ] At least one exercise carries reference velocities
- [ ] `fixtures/LICENCES.md` states what may and may not be used commercially,
      and every fixture in the set is commercially clean or explicitly flagged

## Notes
The licence asymmetry that §15.1 warned about is gone by construction: nothing
here is non-commercial except the two stress-test sets, which are labelled as
such and are not load-bearing. Self-recorded clips are yours outright.

The 200-fixture bar is met mostly by InfiniteRep's synthetic bodyweight clips.
Do not let that flatter the numbers — synthetic bodyweight is the easy case, and
the ~60 self-recorded barbell clips are the ones that decide whether Track A
works. Score them separately (W2-06).
