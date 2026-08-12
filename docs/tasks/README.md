# Tim Method — Task System

63 tasks across 10 waves. Every task traces to a section of [`../SPEC.md`](../SPEC.md).

## How it works

```
docs/tasks/
  open/    wave<N>_<NN>_<slug>.md    not started, or in progress
  done/    wave<N>_<NN>_<slug>.md    finished
```

Finishing a task means moving the file from `open/` to `done/` and flipping
`**Status:**` to `done`. Nothing else. `git log` is the history; the file is the
record of what was actually built and why.

Every file has the same shape: **Goal** (one sentence), **Why** (the reason it
isn't optional), **Do** (concrete steps), **Done when** (verifiable criteria),
**Notes** (the gotcha that will otherwise cost a day).

Waves are ordered by dependency, not by preference. Within a wave, tasks list
their own `Depends on`, and anything without a dependency can run in parallel.

**Waves 1–4 ship no UI at all.** That is deliberate. The counter is the product,
and building it against recorded fixtures is roughly a hundred times faster than
building it against your own body.

## The shape of the thing

Two trackers, one counter. Plate tracking is primary for loaded work because it
is the only approach here with peer-reviewed validation against a linear position
transducer; pose handles form, ROM and bodyweight movements. Both reduce to a
single `RepSignal`, so there is one counter implementation rather than two.
Velocity replaces self-reported RPE, because the camera can measure the former and
the latter is the weakest-evidenced progression method in the literature.

---

## Contents

### Wave 1 — Foundations & Harness · 7 tasks
The eval harness before the app. Ends when a placeholder counter can be scored
against real clips.

| | Task | Spec |
|---|---|---|
| W1-01 | [Xcode project skeleton](open/wave1_01_project-skeleton.md) — four targets, Swift 6 strict | §4.3, §4.4 |
| W1-02 | [FrameSource protocol](open/wave1_02_frame-source.md) — the seam that makes everything testable | §5 |
| W1-03 | [ReplayFrameSource](open/wave1_03_replay-source.md) — `AVAssetReader` into the production path | §5, §15 |
| W1-04 | [Fixture format and loader](open/wave1_04_fixture-format.md) — clip plus ground-truth sidecar | §15 |
| W1-05 | [Evaluation CLI](open/wave1_05_eval-cli.md) — MAE, off-by-one, trace dumps, regression gate | §15.2 |
| W1-06 | [Build the fixture set](open/wave1_06_datasets.md) — no request forms; self-recorded barbell is primary | §15.1 |
| W1-07 | [RepSignal type](open/wave1_07_repsignal.md) — the one abstraction both trackers produce | §6 |

### Wave 2 — Track A: Plate Tracking · 6 tasks
A known-diameter circle gives velocity, bar path and absolute metric scale, and
survives the occlusion that kills pose on loaded lifts.

| | Task | Spec |
|---|---|---|
| W2-01 | [Plate detector core](open/wave2_01_plate-detector.md) — ellipse fit, not circle | §8 |
| W2-02 | [Metric scale](open/wave2_02_metric-scale.md) — pixels to metres, every frame | §8, §6 |
| W2-03 | [Frame-to-frame tracking](open/wave2_03_plate-tracking.md) — local search, occlusion tolerance | §8 |
| W2-04 | [Motion axis fit](open/wave2_04_motion-axis.md) — 2D centroid → 1D `RepSignal` | §6, §8 |
| W2-05 | [Plate configuration](open/wave2_05_plate-config.md) — refuse rather than assume a diameter | §8 |
| W2-06 | [Score Track A](open/wave2_06_track-a-eval.md) — per camera angle; bench press specifically | §15.2 |

### Wave 3 — Rep Counter · 6 tasks
Amplitude gating, not dwell time. Calibration that ratchets one way only.

| | Task | Spec |
|---|---|---|
| W3-01 | [Signal conditioning](open/wave3_01_signal-conditioning.md) — smoothing **off** by default | §4.1, §7.2 |
| W3-02 | [Zero-crossing counter](open/wave3_02_zero-cross-counter.md) — peak → valley → peak | §7.2 |
| W3-03 | [Amplitude gate](open/wave3_03_amplitude-gate.md) — swept displacement, not elapsed time | §7.2 |
| W3-04 | [Ratcheting calibration](open/wave3_04_ratcheting-calibration.md) — fatigue must not lower the bar | §7.3 |
| W3-05 | [Posture gate](open/wave3_05_posture-gate.md) — no phantom reps during setup | §7.1 |
| W3-06 | [Score the counter to target](open/wave3_06_counter-eval.md) — **target, not floor** | §15.2 |

### Wave 4 — Velocity · 5 tasks
The measurement that replaces RPE.

| | Task | Spec |
|---|---|---|
| W4-01 | [Phase split](open/wave4_01_phase-detection.md) — concentric and eccentric boundaries | §8.1 |
| W4-02 | [Mean concentric velocity](open/wave4_02_mean-concentric-velocity.md) — target RMSE ≤ 0.05 m/s | §8.1 |
| W4-03 | [Velocity loss per set](open/wave4_03_velocity-loss.md) — live VL% | §8.1, §11.1 |
| W4-04 | [RIR band](open/wave4_04_rir-band.md) — a band, never an integer | §8.1, §11.1 |
| W4-05 | [Score velocity](open/wave4_05_velocity-eval.md) — check for systematic bias, not just RMSE | §15.2 |

### Wave 5 — Track B: Pose & Bake-off · 8 tasks
Two backends measured against each other, because nobody else has.

| | Task | Spec |
|---|---|---|
| W5-01 | [PoseProvider protocol](open/wave5_01_pose-provider.md) — canonical joints, swappable backend | §4.1 |
| W5-02 | [Apple Vision 3D provider](open/wave5_02_apple-vision-provider.md) — the default | §4.1 |
| W5-03 | [Per-joint confidence gating](open/wave5_03_confidence-gating.md) — floors, not one threshold | §7.1 |
| W5-04 | [Subject lock](open/wave5_04_subject-lock.md) — ignore the rest of the gym | §7.1 |
| W5-05 | [PCA projection](open/wave5_05_pca-projection.md) — pose → the same `RepSignal` | §6 |
| W5-06 | [World angles, ROM as %](open/wave5_06_world-angles-rom.md) — never show absolute degrees | §7.4 |
| W5-07 | [MediaPipe provider](open/wave5_07_mediapipe-provider.md) — the challenger | §4.1 |
| W5-08 | [Bake-off and decision](open/wave5_08_backend-bakeoff.md) — closes open questions 1 and 2 | §4.1, §19 |

### Wave 6 — App Shell · 8 tasks
First wave with a screen.

| | Task | Spec |
|---|---|---|
| W6-01 | [Capture actor](open/wave6_01_capture-actor.md) — global actor over the serial queue | §4.4 |
| W6-02 | [LiveFrameSource](open/wave6_02_live-frame-source.md) — 60fps, no TrueDepth request | §4.2 |
| W6-03 | [Camera permission](open/wave6_03_camera-permission.md) — specific copy, pre-prompt explainer | §17 |
| W6-04 | [Design system](open/wave6_04_design-system.md) — three tokens, accent means one thing | §14.1 |
| W6-05 | [Preview and overlay](open/wave6_05_preview-overlay.md) — redraw on data, not on a timer | §14.2 |
| W6-06 | [The velocity instrument](open/wave6_06_velocity-instrument.md) — legible at 3 metres | §14.1 |
| W6-07 | [Framing guide](open/wave6_07_framing-guide.md) — warn before the set, not after | §14.3 |
| W6-08 | [Thermal ladder](open/wave6_08_thermal-ladder.md) — degrade deliberately | §16 |

### Wave 7 — Sessions & Persistence · 6 tasks
GRDB, automatic set segmentation, history.

| | Task | Spec |
|---|---|---|
| W7-01 | [GRDB schema](open/wave7_01_grdb-schema.md) — migrations from v1 | §12, §13 |
| W7-02 | [Set and rest segmentation](open/wave7_02_set-segmenter.md) — zero manual input | §10 |
| W7-03 | [Session recording](open/wave7_03_session-recording.md) — crash loses at most one rep | §12 |
| W7-04 | [Set summary](open/wave7_04_set-summary.md) — correcting a count is data collection | §14.1, §7.3 |
| W7-05 | [History and trends](open/wave7_05_history.md) — velocity-at-load is the headline chart | §12, §14 |
| W7-06 | [HealthKit workout write](open/wave7_06_healthkit.md) — no rep quantity type exists | §13 |

### Wave 8 — Tim Method Engine · 6 tasks
The training layer. Defined as much by refusals as by prescriptions.

| | Task | Spec |
|---|---|---|
| W8-01 | [Exercise catalog](open/wave8_01_exercise-catalog.md) — 15 movements, muscles, fractional sets | §2, §12 |
| W8-02 | [Volume ledger](open/wave8_02_volume-ledger.md) — 12–20 sets/muscle/week, honest above 25 | §11.2 |
| W8-03 | [Velocity-loss stop cue](open/wave8_03_vl-stop-cue.md) — VL20 default, **never prompt for RPE** | §11.1 |
| W8-04 | [Progression rule](open/wave8_04_progression.md) — double progression, velocity-gated | §11.6 |
| W8-05 | [Deload detection](open/wave8_05_deload.md) — from velocity, not a questionnaire | §11.6 |
| W8-06 | [The honesty page](open/wave8_06_honesty-page.md) — what is measured, how well, what isn't claimed | §17.1 |

### Wave 9 — Few-shot Enrollment · 5 tasks
Thirty exercises without thirty state machines, and without 1,500 videos.

| | Task | Spec |
|---|---|---|
| W9-01 | [Template capture](open/wave9_01_template-capture.md) — demonstrate 2–3 reps | §9.3 |
| W9-02 | [Cycle normalization](open/wave9_02_cycle-normalization.md) — keep the trajectory, not just the scalar | §9.3 |
| W9-03 | [DTW recognition](open/wave9_03_dtw-recognition.md) — labels completed reps, never gates counting | §9.3 |
| W9-04 | [Enrollment interface](open/wave9_04_enrollment-ui.md) — muscle assignment is required | §9.3 |
| W9-05 | [Score enrollment](open/wave9_05_enrollment-eval.md) — a result nobody has published | §15 |

### Wave 10 — Ship Readiness · 6 tasks
Full-featured whether or not it leaves the device.

| | Task | Spec |
|---|---|---|
| W10-01 | [Onboarding](open/wave10_01_onboarding.md) — placement tutorial is the highest-leverage screen | §14.3, §18 |
| W10-02 | [Privacy manifest](open/wave10_02_privacy-manifest.md) — ITMS-91053 blocks upload outright | §17 |
| W10-03 | [Camera-active indicator](open/wave10_03_camera-indicator.md) — guideline 2.5.14 | §17 |
| W10-04 | [Accessibility](open/wave10_04_accessibility.md) — the live instrument is the hard case | §14 |
| W10-05 | [App identity](open/wave10_05_identity.md) — bar-path motif, no placeholders | §14.1 |
| W10-06 | [Release checklist](open/wave10_06_release-checklist.md) — closes every §19 open question | §17, §19 |

---

## Critical path

```
W1-01 → W1-02 → W1-03 ─┐
W1-04 ─────────────────┼→ W1-05 ─→ W2-06 ─→ W3-06 ─→ W4-05 ─→ W5-08
W1-06 ─────────────────┘            ▲         ▲                  │
W1-07 → W2-01 → W2-02 → W2-03 → W2-04         │                  │
                                W3-01 → W3-02 → W3-03 → W3-04    │
                                                W3-05 ───────────┘
                                                                 ▼
                                            W6 (shell) → W7 → W8 → W9 → W10
```

Everything upstream of W3-06 exists to make one number trustworthy. Do not move
past it on floor-grade results.

## Cross-cutting rules

These apply to every wave and are not repeated in each file.

- **Tune against fixtures, never against a live camera.** The whole point of
  Wave 1.
- **No absolute joint angles in the UI, ever.** Elbow flexion error is ≥21.5°
  across every model tested. ROM is a percentage of your own baseline.
- **No RPE prompt anywhere.** The camera measures velocity; that is the thesis.
- **Refuse rather than guess.** No plate diameter means no Track A. No metric
  scale means velocity is `nil`, not zero. A silently wrong number is the worst
  failure this app has.
- **Every rejected rep carries a machine-readable reason** into the trace.
- **Judgment gets labelled as judgment.** The ROM ratchet, set segmentation and
  the deload heuristic have no prior art. Say so in the honesty page.
</content>
