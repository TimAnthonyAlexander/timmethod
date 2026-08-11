# Tim Method — Technical Specification

> Status: draft 1, 2026-08-11. Supersedes the initial AI-rep-counter spec.
> Target: native iOS 26, iPhone 17 Pro Max (dev device), Swift 6.
> Every claim marked ⟨cite⟩ traces to a source in §20. Claims without a citation
> are engineering judgment and are labelled as such.

---

## 1. Thesis

A camera pointed at a lifter can measure three things reliably: **how far the
load moved**, **how fast it moved**, and **how many times**. Everything else a
fitness app normally claims to measure — form scores, injury risk, "muscle
activation" — is either unmeasurable from a single RGB camera or measurable with
error bands so wide the number is theatre.

Tim Method is built on that boundary. It measures the three things it can measure
accurately, uses them to drive training decisions the evidence actually supports,
and explicitly refuses to coach the variables the evidence says don't matter.

The sharpest version of the idea: **the camera replaces self-reported RPE.**
Autoregulating on how hard a set *felt* is the weakest-evidenced progression
method in the literature — a 2026 network meta-analysis of 27 RCTs ranked
RPE-based autoregulation statistically indistinguishable from flat percentage
progression (SMD 0.12, 95% CI −0.31 to 0.56) and dead last of five methods for
jump power. Velocity-based autoregulation, in the same analysis, beat percentages
(SMD 0.41). ⟨B1⟩ The camera can measure velocity. So it should measure velocity,
and never ask you how the set felt.

### Non-goals

- Rep-quality scoring presented as a number ("form: 82/100"). Not measurable to
  that precision. §7.4.
- Injury-risk prediction. No evidence base, and App Store guideline 1.4.1 wants
  methodology disclosed for exactly this kind of claim. ⟨A9⟩
- Coaching lengthened partials, prescribed tempo, or a specific periodization
  model. The evidence does not support any of the three. §11.5.
- Multi-person frames, cloud processing, social features.

---

## 2. Scope

**v1 exercises — loaded, barbell and dumbbell.** Back squat, front squat, bench
press, overhead press, barbell row, Romanian deadlift, deadlift, dumbbell curl,
dumbbell shoulder press, dumbbell row.

**v1 also handles unloaded** movements through the same counter, because the
architecture is signal-source-agnostic (§6): push-up, pull-up, chin-up, dip,
bodyweight squat.

**Extension mechanism, in v1.** Any movement not on the list is added by
demonstrating two to three reps, not by shipping code. §9.3. This is a v1
requirement, not a later feature, because the alternative — a supervised
classifier — needs roughly 50 videos per class ⟨C7⟩ and we are not recording
1,500 videos.

---

## 3. Architecture

The central decision: **two independent signal sources, one counter.**

```
                    ┌─────────────────────────────────────────┐
                    │  AVCaptureSession  (60fps, 1080p)       │
                    │  front TrueDepth cam (RGB only) or       │
                    │  rear wide + LiDAR depth (optional)      │
                    └───────────────┬─────────────────────────┘
                                    │ CMSampleBuffer
                    ┌───────────────┴─────────────────────────┐
                    │        FrameSource  (protocol)          │
                    │  LiveFrameSource | ReplayFrameSource    │
                    └───────────────┬─────────────────────────┘
                                    │
              ┌─────────────────────┴──────────────────────┐
              │                                            │
    ┌─────────▼──────────┐                    ┌────────────▼─────────┐
    │  TRACK A           │                    │  TRACK B             │
    │  PlateTracker      │                    │  PoseProvider        │
    │  known-Ø circle    │                    │  AppleVision3D       │
    │  → metric scale    │                    │  | MediaPipe         │
    │  → bar path        │                    │  → 17/33 landmarks   │
    └─────────┬──────────┘                    └────────────┬─────────┘
              │                                            │
              │  1D displacement (metres)                  │  1D PCA projection
              │  + absolute scale                          │  + scale from Track A
              │                                            │  or bodyHeight
              └──────────────────┬─────────────────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │  RepSignal                │
                    │  scalar series + metric   │
                    │  scale + confidence       │
                    └────────────┬──────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
┌───────▼────────┐    ┌──────────▼─────────┐   ┌──────────▼─────────┐
│ RepCounter     │    │ SetSegmenter       │   │ ExerciseRecognizer │
│ zero-cross +   │    │ periodicity gate   │   │ DTW vs enrolled    │
│ amplitude gate │    │ → set start/end    │   │ templates          │
└───────┬────────┘    └──────────┬─────────┘   └──────────┬─────────┘
        │                        │                        │
        └────────────────────────┼────────────────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │  TimMethod engine (§11)   │
                    │  VL% → RIR → set/stop     │
                    │  volume ledger            │
                    │  progression              │
                    └────────────┬──────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │  UI · GRDB · HealthKit    │
                    └───────────────────────────┘
```

Why two tracks rather than one. Pose estimation fails on exactly the movements
this app is for. The most rigorous open powerlifting pose project drops bench
press from scope entirely, in its own words, "due to the practical challenges
faced when using a 2D camera to capture footage (obstructed joints)." ⟨B5⟩ A
barbell occludes the hands; plates occlude the hips; a bench puts the lifter
horizontal and side-on. Meanwhile the plate — a high-contrast circle of fixed,
known diameter — stays visible in every one of those cases.

Why the plate track is primary for loaded work. It is the only approach in this
space with peer-reviewed validation against a criterion instrument. Renner,
Mitter & Baca (PLOS ONE, Nov 2024) benchmarked three iPhone camera apps against
Vicon 3D motion capture at 200 Hz and a RepOne linear position transducer, using
competitive powerlifters on squat, bench and deadlift. The best performer reached
RMSE 0.01–0.04 m/s with zero missed reps and R² = 0.9959, against the LPT's own
R² = 0.9983 — statistically equivalent to the reference hardware. ⟨B2⟩ It does
this by tracking a circular object of known real-world size. No pose model
involved.

Why that matters beyond velocity: a plate of known diameter supplies **absolute
metric scale in the image plane**, for free, on every iPhone, with no depth
sensor. That is the same problem `bodyHeight` was going to solve, except
`bodyHeight` only returns a *measured* value when the capture session uses the
LiDAR camera and otherwise silently substitutes a fixed 1.8 m reference. ⟨A3⟩ On
a non-Pro device that fallback injects an error proportional to
(true height − 1.8)/1.8 into every metric quantity downstream.

---

## 4. Platform and stack decisions

### 4.1 Pose backend — `PoseProvider` protocol, Apple Vision 3D default

**Decision: ship a protocol with two implementations; the harness picks per
exercise. Apple Vision 3D is the default first implementation.**

Candidates and why they were ranked this way:

| Backend | Landmarks | Metric 3D | Licence | Verdict |
|---|---|---|---|---|
| Apple Vision `DetectHumanBodyPose3DRequest` | 17 | Yes, hip-origin `cameraOriginMatrix` | Platform | **Default** |
| MediaPipe Pose Landmarker | 33 | Yes, `worldLandmarks`, metres, mid-hip origin | Apache 2.0 | **Challenger** |
| YOLO26-pose | 17, 2D only | No | AGPL-3.0 | Rejected |
| RTMPose | 17 / 133 | No | Apache 2.0 | Rejected |
| MoveNet | 17, 2D only | No | Apache 2.0 | Rejected |

YOLO26-pose is the fastest thing anyone has measured — 3.9 ms per frame on the
Neural Engine on an iPhone 17 Pro, versus 11.9 ms CPU-only ⟨C1⟩ — and it is
rejected anyway. Not primarily on the licence, though AGPL-3.0 covers the trained
weights and would force open-sourcing the entire app on distribution ⟨C1⟩. It is
rejected because 17 COCO keypoints in 2D image space cannot produce
camera-invariant angles at any speed, and camera invariance is the whole point of
§7. RTMPose and MoveNet fail the same test and additionally have no maintained
Core ML export path. ⟨C3⟩

Between the two survivors, **no benchmark comparing them exists anywhere.** The
best study in the field — Rode et al., *Scientific Reports*, Nov 2025, eleven
models against marker-based mocap — does not include Apple Vision at all. ⟨A4⟩ So
the default is chosen on integration cost and thermal behaviour, which are
evidenced, and revisited on accuracy once the harness has data.

Reasons Apple Vision starts as default:

1. **Zero dependency.** MediaPipe is CocoaPods-only in 2026; the SPM request has
   been open and unanswered since June 2024. ⟨A1⟩ Adding CocoaPods to an
   otherwise-SPM project for one dependency is a real cost.
2. **Binary weight.** The `MediaPipeTasksCommon` podspec `-force_load`s a 430 MB
   unstripped device archive, which pulls in every vision task — face, hand,
   segmentation, detection — whether used or not, and explicitly defeats linker
   dead-stripping. ⟨A1⟩
3. **Thermal stability over a 60-minute session.** Sustained-load measurement
   found the Neural Engine holding ~67% of peak throughput after ten minutes
   while GPU fell to 38–48%. ⟨A8⟩ Apple Vision is ANE-backed. MediaPipe's GPU
   delegate has open reports of memory growth and crashes on long camera
   sessions ⟨A1⟩, so it would run on CPU regardless.
4. **Confidence values that exist.** MediaPipe's `visibility` and `presence` have
   a long history of returning nil across platforms, including an iOS-specific
   report of `poseWorldLandmarks` coming back empty. ⟨A1⟩ Confidence gating (§7.1)
   depends on those values being populated.

MediaPipe's genuine advantages, which are why it stays as a challenger rather
than being cut: 33 landmarks including feet and hands, and BlazePose-Heavy posted
the best pure-3D error in the one benchmark that exists (146 mm MPJPE). ⟨A4⟩

**Do not add a One Euro filter per landmark.** MediaPipe already applies one
internally in stream mode — 2D normalized at min_cutoff 0.05 / beta 80, world
landmarks at 0.1 / 40 ⟨A5⟩ — so a second filter double-smooths and stacks lag.
Whether Apple Vision filters internally is undocumented; measure jitter on a
static subject before adding anything. If smoothing is needed, apply it to the
**1D `RepSignal`**, not to 33 landmarks × 3 coordinates. One filter, one parameter
pair, a third of the lag, and it is the only signal the counter reads anyway.

### 4.2 Camera

| Setting | Value | Reason |
|---|---|---|
| Camera | Front, default | Screen must be visible during the set; feedback is screen-only |
| Rear + LiDAR | Configurable option | Pro/Pro Max only; better lens; enables *measured* `bodyHeight` |
| Resolution | 1920×1080 | Plate detection wants pixels on the plate rim; pose models downscale anyway |
| Frame rate | 60 fps | See below |
| Pixel format | `32BGRA` | Direct CoreImage/Metal path for plate detection |
| `alwaysDiscardsLateVideoFrames` | `true` | Drop, never queue ⟨A6⟩ |
| Orientation | `videoRotationAngle` + `RotationCoordinator` | `videoOrientation` deprecated since iOS 17 ⟨A6⟩ |

**60 fps, not 30.** Bardella et al. (2017), validating against a 200 Hz linear
encoder, found 25 Hz "more than adequate" to record raw barbell speed, with the
individually-required maximum at 17.5 Hz. ⟨B3⟩ So 30 fps clears the *physical*
bandwidth of the lift. But the best-validated camera VBT app runs at 60 fps ⟨B2⟩,
and the error source that actually bites is detection jitter in the CV pipeline,
not signal bandwidth. Metric VBT's documented failures were missed reps and
velocity underestimation — detection problems, not sampling problems. ⟨B2⟩ 60 fps
buys margin against that at no meaningful cost on this hardware. Pose inference
runs on every second frame; plate detection on every frame.

**TrueDepth is RGB-only for our purposes.** No Apple spec publishes a hard range,
but converging vendor and Apple-DTS evidence puts usable TrueDepth depth at
≤ 1 metre. ⟨B4⟩ Framing a standing lift needs 2–3 m. Front-facing depth is dead
weight; do not request it.

**LiDAR is optional and low-rate.** Max range 5 m ⟨B4⟩, which does cover framing
distance, but depth frame rate is not independently settable — it follows the
video range and drops when the system can't keep up, and Apple explicitly warns
depth delivery "may increase system load, resulting in a reduced video frame rate
for thermal sustainability." ⟨B4⟩ Treat depth as an occasional signal for
one-time calibration, never as a per-frame input.

### 4.3 App stack

| Concern | Choice | Reason |
|---|---|---|
| Deployment target | iOS 26.0 | Single known device; 79% of all iPhones already on 26 ⟨A2⟩ |
| Language | Swift 6.3, strict concurrency on | New target, no migration debt |
| UI | SwiftUI | — |
| Persistence | **GRDB** | §13 |
| Overlay rendering | SwiftUI `Canvas`, redrawn on new pose only | §14.2 |
| Camera isolation | Custom `@globalActor` over a serial `DispatchQueue` executor | §4.4 |
| Charts | Swift Charts | — |

### 4.4 The concurrency shape

`CVPixelBuffer` and `CMSampleBuffer` are still not `Sendable` in 2026, and
`@preconcurrency import CoreVideo` does not silence it. Apple's own AVCam sample
fails to build under strict Swift 6 checking without `@preconcurrency import
AVFoundation`. ⟨A7⟩ This is the single most-reported friction point in the
ecosystem and it is not going to be fixed for us.

The pattern, which two independent sources converge on ⟨A7⟩:

```swift
@globalActor actor CaptureActor {
    static let shared = CaptureActor()
    // backed by a custom SerialExecutor wrapping the serial DispatchQueue
    // AVFoundation already requires, so actor isolation and queue identity
    // are the same thing and there is no extra hop.
}
```

The `AVCaptureVideoDataOutputSampleBufferDelegate` conformer is a **private
nested class living entirely inside the actor**. Raw buffers never escape it.
What crosses to `@MainActor` is a `Sendable` value type — a `PoseFrame`, a
`PlateObservation`, a `RepEvent` — pushed over an `AsyncStream`. No `@Published`
inside the actor; it is not isolation-safe there. `@unchecked Sendable` is a
documented, minimised stopgap at exactly one boundary, never an architecture.

---

## 5. Frame sourcing and the replay path

This exists from commit one, not as a testing afterthought. Tuning a counter
against a live camera means doing squats between parameter changes.

```swift
protocol FrameSource: Sendable {
    var frames: AsyncStream<TimedFrame> { get }
    func start() async throws
    func stop() async
}

struct TimedFrame: @unchecked Sendable {   // the one sanctioned exception
    let buffer: CVPixelBuffer
    let timestamp: CMTime
    let depth: AVDepthData?   // nil unless rear+LiDAR calibration pass
}
```

`LiveFrameSource` wraps `AVCaptureVideoDataOutput`. `ReplayFrameSource` pulls
`CMSampleBuffer`s from a `.mov` via `AVAssetReader` and
`copyNextSampleBuffer()`, feeding the identical downstream path. This is
Apple-endorsed — an Apple media engineer describes exactly this on the developer
forums, and Apple's own "Action & Vision" sample ships a dual live/file-backed
capture controller. ⟨A9⟩ The Simulator has no camera in 2026 ⟨A9⟩, so replay is
also the only way to iterate without standing up.

Everything downstream of `FrameSource` — trackers, counter, segmenter, Tim Method
engine — depends only on the protocol and is therefore fully testable headlessly.

---

## 6. `RepSignal` — the unifying abstraction

Both tracks reduce to the same thing. This is the design's load-bearing
simplification: **one counter implementation, two signal sources.**

```swift
struct RepSignal {
    /// Scalar samples of the dominant motion axis, in metres.
    /// Positive = away from the ground along the lift's working axis.
    let samples: RingBuffer<Sample>

    struct Sample {
        let t: TimeInterval
        let x: Double          // metres, absolute
        let confidence: Double // 0…1
    }

    /// How metres were established. Determines trust in absolute amplitudes.
    let scale: ScaleSource
    enum ScaleSource {
        case plateDiameter(mm: Double)     // best: known object, ±1%
        case lidarBodyHeight(m: Double)    // good: measured
        case referenceHeight               // poor: Apple's 1.8 m fallback
        case torsoRelative                 // no absolute scale; ratios only
    }
}
```

Track A produces it from plate centroid displacement along the fitted motion
axis. Track B produces it by projecting smoothed landmark positions onto the
first principal component of the trajectory over a sliding window.

The PCA route is not invented here. It is what NEX Team patented and shipped in
HomeCourt: project landmark motion onto PCA axes in a sliding window to get a 1D
signal, then zero-cross with a debounce that merges crossings whose magnitude
difference falls below a threshold. ⟨A10⟩ It is the only signal-processing rep
method with evidence of surviving contact with a real product.

---

## 7. Rep counting

### 7.1 Gating

Before a sample enters the signal:

- **Per-joint confidence floors, not one global threshold.** Reported working in
  production: accepting squat hip confidence down to 0.2 while holding other
  joints higher, interpolating through low-confidence stretches up to 5 frames,
  and applying hard anatomical constraints such as "knee cannot be above hip."
  ⟨A11⟩ A single global cutoff throws away usable frames and keeps unusable ones.
- **Side selection.** Left and right are not equally visible; one is occluded
  most of the time. Take the higher-confidence side per frame, or a
  confidence-weighted average. Never a naive mean.
- **Subject lock.** Centroid-based tracking that locks the largest/nearest person
  across frames and ignores others — the documented working fix for gym
  bystanders. ⟨A11⟩
- **Posture gate.** Confidence is not the same question as "is this person doing
  the exercise." Standing up, walking to the rack, and lying down all sweep the
  full signal range. Torso orientation relative to gravity plus coarse landmark
  layout gates the counter shut outside the movement. Without this the counter
  fires during setup, and the first thing you see is a broken number.

### 7.2 The counter

Zero-crossing with hysteresis and an **amplitude gate**, not a time-based
debounce.

```
signal → detrend (rolling median, 3s window)
       → velocity = d/dt
       → zero crossings of velocity, sign-alternating
       → candidate rep = (peak → valley → peak)
       → ACCEPT iff:
             peak-to-valley amplitude ≥ A_min
         AND phase duration ≥ 80 ms
         AND mean confidence over the cycle ≥ C_min
         AND posture gate held throughout
```

**Why amplitude, not dwell time.** The original spec's `MIN_PHASE_MS` of
150–250 ms assumes the lifter pauses at the bottom. Explosive reps don't, and
missing an athlete's fast reps is a worse failure than counting a twitch.
Requiring a minimum swept displacement rejects noise for the same reason a dwell
requirement does, but is speed-neutral. The 80 ms floor stays only to kill
single-frame spikes. This also collapses the original four named thresholds to
one amplitude and one margin. There is direct support for combining amplitude
with duration rather than amplitude alone to separate partial reps from full
ones ⟨A12⟩; what is rejected here is duration as the *primary* gate.

`A_min` comes from calibration (§7.3), expressed in metres when scale is
`plateDiameter` or `lidarBodyHeight`, and as a fraction of torso length otherwise.

**A rep counts on the return to the start position, never on reaching the
bottom.** An abandoned rep is not a rep.

### 7.3 Calibration that ratchets

Rolling auto-calibration as originally specified will count half reps. As a
lifter fatigues, range of motion shrinks; if thresholds track observed extremes,
they follow the fatigue down and shallow reps keep counting — precisely the rep
the counter exists to reject. This failure mode has no documented shipped
mitigation anywhere in the literature. ⟨A13⟩

The rule here:

- Establish range from the **first three accepted reps** of a set.
- Set `A_min` at **80% of that established amplitude**.
- Within a set, the range may **expand only**. A rep larger than the established
  range raises the baseline. A rep smaller does not lower it.
- A rep between 50% and 80% of range is recorded as a **partial** — counted in a
  separate ledger, shown in the set summary, and excluded from the working rep
  count.
- Below 50%: not a rep.
- Across sessions, the per-exercise baseline is the **median of session maxima**,
  not a running mean, so one deep warm-up rep doesn't reset the standard and one
  bad day doesn't erode it.

### 7.4 Angles: measured, never displayed as absolute

Joint angles are computed for form checks and ROM reporting. They are never shown
to the user as absolute degrees, and never used as counting thresholds.

Rode et al. (2025), eleven models against marker-based mocap, found knee flexion
error ≥ 9.3° and **elbow flexion error ≥ 21.5°** in 2D — across every model
tested. ⟨A4⟩ The original spec keyed push-ups and pull-ups on elbow angle. A ±21°
band swamps any threshold worth setting.

The error is, however, largely *systematic* for a fixed camera position and
subject. So relative comparison holds where absolute does not. ROM is therefore
reported as **percentage of your own established range for that exercise**, and
form flags are expressed as deviations from your own baseline, never against a
population norm.

When the pose track has metric world coordinates, angles are computed in world
space, not image space. A 2D projected angle depends on camera azimuth; the same
push-up filmed head-on and 40° off-axis yields different elbow angles, and
accuracy is reported to degrade past roughly 30° off-perpendicular. ⟨A11⟩ World
coordinates are the fix, and they are available from both surviving backends
(§4.1) — this is not a later feature.

---

## 8. Track A: plate detection

The validated technique, reimplemented. Three independent shipped products
converge on it ⟨B2⟩: track a **circle of known real-world diameter**, not the
barbell, not the body.

- **Detection.** Hough circle transform or an ellipse fit on gradient edges,
  constrained by expected radius range. The plate projects to an ellipse when
  off-axis; the **major axis** is the true diameter and is rotation-invariant, so
  fit the ellipse and use its major axis rather than assuming a circle.
- **Known diameters.** Olympic plate 450 mm. Bumper plates 450 mm. Standard
  1-inch plates vary; user picks from a list at enrollment, or measures once
  against a reference. Dumbbells: user enters the end-cap diameter once per pair.
- **Scale.** `pixels_per_metre = major_axis_px / plate_diameter_m`. Recomputed
  every frame, so it survives the lifter drifting toward or away from the camera.
- **Tracking.** Detect on frame 1, then track by local search around the previous
  centroid with periodic full re-detection. Cheap, and robust to a second plate
  entering frame.
- **Occlusion.** When the plate is briefly hidden (a hand, a rack upright),
  interpolate up to 5 frames, then declare loss.
- **Bar path.** The centroid trace in metres, in the sagittal plane, is the bar
  path. This is a real output, and it is honest — it's a measured trajectory of a
  tracked object, not an inferred skeleton.

**No barbell object detection.** There is no mature, validated, open model for
it; the community datasets on Roboflow are 92 to 1,712 unvalidated images. ⟨B5⟩
And consumer bar-path apps (Iron Path, BarSense) require the user to manually
seed a marker. ⟨B5⟩ The plate is the tractable target.

**ARKit object tracking is not the answer either.** iOS 27 does bring object
tracking to iPhone for the first time, with a new high-frame-rate
`.trackingObjects` mode aimed at moving objects. ⟨B6⟩ But a bare barbell is close
to worst-case for scan-based tracking: symmetric, thin, textureless, reflective.
Apple's own sanctioned fallback is attaching a printed marker to the object
⟨B6⟩ — real, newly available, and a product-friction cost that no shipped VBT
product pays because plate-diameter tracking needs no attached hardware.

### 8.1 Velocity and the VL → RIR mapping

Mean concentric velocity per rep, from the metric displacement signal.

Velocity loss across a set tracks proximity to failure tightly. Rodríguez-Rosell
et al. (2020) report r = 0.97 for bench press and r = 0.93 for back squat between
velocity loss and percentage of reps completed. ⟨B7⟩

The caveat is load-bearing and goes in the UI, not just this document. Individual
variability at matched velocity loss is real: coefficient of variation for
rep-completion is 15–22% on bench and 26–34% on squat. ⟨B7⟩ And a 2025 systematic
review found velocity-at-failure reliable in rested conditions but degrading
substantially under fatigue and short rest, except in lifters with more than two
years of to-failure training experience. ⟨B8⟩ So VL-derived RIR is presented as a
band, never a single integer, and the band widens as the session accumulates
fatigue.

**1RM estimation from a load-velocity profile is not shipped in v1.** A 2024
meta-analysis of 27 effects found the minimum-velocity-threshold method
*systematically overestimates* back squat 1RM (measured 86.5–153.1 kg vs
estimated 88.6–171.6 kg), with an explicit "exercise caution" conclusion. ⟨B9⟩
Minimum velocity thresholds also vary hard between individuals — 0.27 m/s vs
0.39 m/s at 1RM for two lifters in the same study. ⟨B10⟩ Estimating your 1RM
badly is worse than not estimating it.

---

## 9. Exercise recognition and enrollment

### 9.1 Class-agnostic counting is a fallback, not the plan

RepNet, evaluated correctly with multi-speed playback, reaches MAE 0.331 and only
53.3% off-by-one accuracy on RepCount-A. The 2024 state of the art, ESCounts,
manages 56.3%. ⟨C4⟩ Being off by one on a set of ten, more than 40% of the time,
is not a product. Class-agnostic periodicity detection runs continuously anyway
because it powers set segmentation (§10), but it does not produce the number on
screen for a known exercise.

Note also the evaluation controversy: several follow-up papers benchmarked a
"modified RepNet" that scores far worse (OBO 1.3%) than the original evaluated
properly. ⟨C4⟩ Do not trust cross-paper comparisons in this literature.

### 9.2 A supervised classifier is ruled out by the data budget

Create ML's Action Classifier is still live and documented, built on Vision body
pose under the hood, and needs roughly **50 example videos per class** plus a
negative class. ⟨C7⟩ Thirty exercises is 1,500 recordings. That is not happening,
so the classifier path is closed regardless of its merits. Skeleton-GCN models
scale to 60–120 classes at 90%+ with under 4M parameters ⟨C1⟩ and would run fine
on-device, but they need the same labelled data we don't have.

### 9.3 Few-shot enrollment is the mechanism

Demonstrate two to three reps. The system stores a template and thereafter counts
and recognises that movement.

Published support, all adjacent rather than exact:

- Siamese network with triplet loss on IMU signals, evaluated across 28
  exercises: **86.8% probability of correctly counting sets of 10+ reps for
  exercises unseen in training.** ⟨C5⟩
- ExerSense: correlation-based template matching from **a single demonstration
  per exercise**, doing segmentation, classification and counting together, 95%
  across five exercises. ⟨C5⟩
- JEANIE: few-shot skeleton action recognition via joint temporal-viewpoint
  alignment, a DTW-family method built for exactly this matching problem in the
  pose domain. ⟨C5⟩

The first two are IMU rather than pose, so the concept transfers and the numbers
do not. JEANIE is pose-domain and is the right architectural starting point.

Implementation: store each enrolled exercise as a normalised single-cycle
`RepSignal` template plus its landmark trajectory. Recognition is DTW distance
against the enrolled set, on the normalised cycle. Enrollment asks for the
exercise name, the equipment, and the plate diameter if loaded.

**Streaming DTW caveat.** Full-sequence DTW is well-behaved; the published
pose-domain work is not streaming, and PoseSync's accuracy falls to 62–87% under
action reordering ⟨A14⟩ — which is what fatigue drift and partial reps look like
to a fixed template. So DTW classifies *completed* cycles that the amplitude
counter has already accepted. It never gates counting. Ordering matters here.

---

## 10. Set and rest segmentation

Zero manual input during a workout is a requirement, not a nicety.

No pose-only published approach to "detect set start/end versus walking around
and racking a bar" was found. ⟨C6⟩ The nearest reference architecture is MM-Fit,
which treats segmentation, recognition and counting as one joint pipeline, but
multimodally with wearables. ⟨C6⟩

The approach here, which is engineering judgment built on the available signal:

A **set** is a maximal window where the periodicity strength of the `RepSignal`
exceeds a threshold, the posture gate holds, and subject-lock confidence holds.
Everything else is rest. The periodicity estimate comes free from the
class-agnostic detector already running (§9.1) — it is a poor rep *counter* but a
perfectly good "is this periodic right now" detector, which is a much easier
question.

Set ends when periodicity collapses for more than 4 seconds or the posture gate
opens. Rest timing starts on set end. Rest is a first-class measurement, because
§11.4 needs it.

Short-time energy of the movement signal is a documented complementary cue for
rep and set boundaries ⟨C6⟩ and is cheap to add if periodicity alone proves noisy.

---

## 11. The Tim Method training layer

The rule for this layer: **prescribe only what the evidence supports, and
explicitly decline to prescribe what it doesn't.** Where the literature is
contested, the app says so rather than picking the marketable side.

### 11.1 Effort — measured, not asked

Hypertrophy improves as sets approach failure; strength is largely insensitive to
proximity to failure across a wide range. This is the settled shape of the
literature, from the first meta-regression to treat RIR as continuous (55
hypertrophy studies, 67 strength studies): the hypertrophy slope is negative with
CI excluding zero, the strength slope's CI contains zero. ⟨D1⟩

The effect is real but small, and honest framing matters. Failure versus
non-failure for hypertrophy comes out at ES 0.19 (95% CI 0.00–0.37) overall, and
the momentary-failure subgroup is non-significant at ES 0.12. ⟨D2⟩ The one clearly
positive result in the whole failure literature is in resistance-trained subjects
specifically, ES 0.15 (0.03–0.26). ⟨D3⟩ And when volume is equalised, the apparent
hypertrophy advantage of training to failure disappears entirely — it was a
volume confound. ⟨D4⟩

**Prescription: 0–2 RIR on working sets, estimated from velocity loss, never from
a self-report prompt.** Target VL20 as the default stop cue. Pareja-Blanco et al.
(2017) found VL20 produced better countermovement-jump improvement than VL40
(9.5% vs 3.5%) despite 40% fewer total reps; the 2020 four-arm study (0/10/20/40%
VL, n=64, 8 weeks) found no between-group strength difference, more hypertrophy
at VL20 and VL40 than VL0/VL10, and — importantly — that VL40 alone significantly
slowed muscle activation delay and cut early rate of force development. ⟨D5⟩
Excess velocity loss buys hypertrophy at a measurable neuromuscular cost.

A hypertrophy-biased block may raise the cutoff toward VL30. The app makes that a
visible block-level setting, with the tradeoff stated.

### 11.2 Volume — a ledger, with honest uncertainty at the top end

The dose-response for hypertrophy keeps rising through the tested range and
decelerates hard. The 2026 Bayesian meta-regression (hypertrophy models on 35
studies / 1,032 participants) fits a square root with slope 0.24% extra size per
fractional set (0.15–0.33%) at a dataset mean of 12.25 sets/week, and identifies
no plateau — but with CIs wide enough at high volume to be compatible with one.
⟨D6⟩ Its efficiency tiers are the practically useful part: reaching the next
detectable increment costs about 6 extra sets at 5–10 sets/week, and about 12.5
extra at 30–42. Above 43 sets/week the data is too thin to say anything.

Strength's curve is much flatter — a reciprocal fit that functionally plateaus,
with added sets past roughly 5/week not reliably clearing detectability. ⟨D6⟩

Two corrections that go in the app's own copy, because both are widely
misreported:

- The famous Schoenfeld 2017 categorical split (<5 / 5–9 / 10+ sets per week)
  **was not significant, p = 0.074.** Only the continuous slope held up, at
  +0.37% hypertrophy per set. ⟨D7⟩
- Barbalho et al. 2020, the study behind the "5–10 sets is enough, more is worse"
  claim, **was retracted in June 2020** and still circulates uncredited. ⟨D8⟩

**Prescription: 12–20 hard sets per muscle per week as the working band**, which
captures the large majority of achievable growth at sane cost. Indirect sets
count as 0.5 ⟨D6⟩. The app maintains a rolling weekly ledger per muscle group and
warns above 25 sets/week that the evidence thins out rather than pretending to
know the ceiling. Per-session it caps at **~11 fractional sets per muscle**, past
which added sets in one sitting stop paying off. ⟨D9⟩

### 11.3 Frequency

At matched weekly volume, frequency does not move hypertrophy. This is not
seriously contested — the 2019 meta-analysis found ES 0.07 (−0.08 to 0.21) for
volume-equated direct-measure studies ⟨D10⟩, and the 2026 meta-regression's
hypertrophy-frequency CI crosses zero. ⟨D6⟩

For **strength this is a live disagreement in 2026** and the app should not
pretend otherwise. Four older meta-analyses found nothing once volume was
equated. The newest and largest found 3.27% per session (2.74–3.84%), with nearly
all of it in the 1→2 sessions jump, and its authors write plainly that the
finding "is in contradiction to previous meta-analyses," proposing motor-skill
practice rather than muscle biology as the mechanism. ⟨D6⟩

**Prescription: 2–3 sessions per muscle per week** — justified regardless of how
that disagreement resolves, because it is the way to fit 12–20 weekly sets under
an ~11-set per-session ceiling. Frequency is a volume-delivery vehicle here, not
a claimed independent lever.

### 11.4 Rest

Longer rest reliably wins for strength — a 2025 preprint restricted to trained
males puts it at SMD −0.74. ⟨D11⟩ For hypertrophy the effect has shrunk steadily:
from Schoenfeld 2016's clear advantage (3-min vs 1-min: squat +15.2% vs +7.6%
strength; anterior quad +13.3% vs +6.9% thickness) ⟨D12⟩, through a Bayesian
meta-analysis finding no meaningful benefit past ~90 seconds with all CIs crossing
zero ⟨D13⟩, to that same 2025 preprint finding only SMD 0.08 in trained males.
⟨D11⟩ The mechanism looks to be volume-load mediation: short rest is fine for
hypertrophy *if* you hold volume constant, which is hard because fatigue drives
volume down on its own. ⟨D14⟩

**Prescription: 2–3 minutes on compounds, ≥90 seconds on isolation.** The app
times rest automatically (§10) and, rather than enforcing a countdown, flags when
the *next set's* first-rep velocity comes in low — which is the direct
observation of "you didn't rest enough" rather than a proxy for it.

### 11.5 What the app deliberately does not prescribe

**Tempo.** Irrelevant for hypertrophy once effort and volume are matched, from
four independent directions: the 0.5–8 s equivalence band ⟨D15⟩, a 2025 pooled
eccentric-duration estimate of g = 0.05 (90% CI −0.22 to 0.33) ⟨D16⟩, a 44-review
umbrella finding insufficient evidence ⟨D17⟩, and the 2026 ACSM Position Stand
declining to recommend a tempo at all. ⟨D18⟩ There is one live exception —
longer eccentrics show a small, moderately-certain *strength* benefit in trained
lifters, g = 0.25–0.33 ⟨D16⟩ — which is surfaced as an optional block setting, not
a default. The app records tempo because it can, and does not coach it.

**Lengthened partials.** Full ROM beating *shortened* partials is solid: ES 0.56
for strength and 0.88 for lower-body hypertrophy across 16 studies. ⟨D19⟩ The
stronger claim — that partials emphasising the stretched position beat full ROM —
is weak and has been walked back by the researchers who popularised it. Its
load-bearing number is a **non-significant subgroup**, SMD −0.28 (95% CI −0.81 to
0.16) ⟨D20⟩. The best-powered trial in the field, n = 297 across 15 sites, found a
thigh-CSA condition×time interaction of **0.000** ⟨D21⟩; a 2025 meta-analysis
across muscle lengths found SMDs of 0.05–0.09 with every CI touching zero ⟨D22⟩;
and a within-subject trained-lifter study returned Bayes factors of 0.16–0.3, or
moderate evidence *for* the null. ⟨D23⟩ The direction isn't even consistent by
muscle — middle-range partials beat full ROM for triceps by ES 1.21, the largest
effect in the review that reported it. ⟨D24⟩

So: the ROM tracker penalises truncated reps, which is meta-analytically
supported, and never coaches stretched-position partials as superior, which would
be running ahead of the evidence.

**A periodization model.** LP versus DUP is d = −0.02. ⟨D25⟩ And the
periodization-beats-non-periodization result (ES 0.43) is confounded: a
re-examination of all 21 underlying primary studies found **none of them compared
periodization against a *varied* non-periodized program** — the control arms were
flat and unvaried. ⟨D26⟩ The comparison everyone cites has never been run. Tim
Method runs velocity-anchored double progression and doesn't claim a periodization
scheme.

### 11.6 The progression rule

```
For each exercise, each session:
  target = established working load
  perform sets to VL20 (or the block's cutoff)
  if reps_at_target ≥ top of rep range on all sets
     and first-rep velocity ≥ velocity floor for that load:
        increase load next session
  if first-rep velocity has dropped ≥ 10% at the same load
     across two consecutive sessions:
        flag accumulated fatigue → deload prompt
```

This is double progression with a velocity gate. Double progression itself has no
direct study isolating it — PubMed returns nothing comparing it head-to-head, so
it is an expert heuristic and is labelled as such ⟨D27⟩. The velocity gate is the
part with support: load/velocity-based autoregulation beat flat percentage
progression (SMD 0.41) in the 2026 network meta-analysis where RPE-based
autoregulation did not (SMD 0.12, non-significant) ⟨B1⟩, and VBT has been shown to
reach comparable strength gains on 6–9% less volume. ⟨D28⟩ That is an efficiency
result rather than a superiority result, and is presented that way.

### 11.7 Expectation setting

The app shows realistic rates, with the caveat attached. The ubiquitous
"1–1.5% bodyweight per month" table is an expert heuristic with no published
dataset behind it, is routinely misattributed to Lyle McDonald when the
%-bodyweight framing is Alan Aragon's, and the two models disagree by roughly 2×
at year one. ⟨D29⟩ What real longitudinal data says: across 287 previously
untrained people over 20–24 weeks, mean muscle size increase was 4.8 ± 6.1% with a
range of **−11% to +30%**, 14% high responders and 29% indistinguishable from
non-training controls. ⟨D30⟩ Individual variability is the largest single factor
and it is not something the app can predict for you.

---

## 12. Data model

```swift
struct Session {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var sets: [WorkSet]
    var deviceTier: DeviceTier
    var thermalEvents: [ThermalEvent]
}

struct WorkSet {
    let id: UUID
    let exerciseId: Exercise.ID
    let startedAt: Date
    let endedAt: Date
    let restBeforeSec: TimeInterval?

    var reps: [Rep]
    var partialReps: Int          // 50–80% of range, counted separately
    var load: Load?               // user-entered or plate-inferred
    var velocityLossPct: Double   // (first rep MCV − last rep MCV) / first
    var estimatedRIRBand: ClosedRange<Double>?
    var stopReason: StopReason    // .velocityLoss, .repTarget, .manual, .trackingLost
    var scaleSource: RepSignal.ScaleSource
    var trackConfidence: Double
}

struct Rep {
    let index: Int
    let startedAt: TimeInterval
    let concentricMs: Double
    let eccentricMs: Double
    let meanConcentricVelocity: Double?   // m/s, nil if no metric scale
    let peakVelocity: Double?
    let romMetres: Double?
    let romPctOfBaseline: Double          // the number actually shown
    let barPath: [SIMD2<Double>]?         // sagittal, metres, Track A only
    let signalTrace: [Float]              // downsampled, for the harness
}

struct Exercise {
    let id: String
    var displayName: String
    var equipment: Equipment          // .barbell, .dumbbell, .bodyweight, .machine
    var plateDiameterMm: Double?
    var primaryMuscles: [Muscle]
    var secondaryMuscles: [Muscle]    // count 0.5 toward volume ledger
    var preferredTrack: Track         // .plate, .pose, .auto
    var template: MovementTemplate?   // from few-shot enrollment
    var baselineROM: Double?          // median of session maxima
    var repRange: ClosedRange<Int>
    var velocityLossTarget: Double    // default 0.20
}

struct MovementTemplate {
    let normalizedCycle: [Float]          // resampled to fixed length
    let landmarkTrajectory: [[SIMD3<Float>]]?
    let enrolledAt: Date
    let exampleCount: Int
}
```

Every `Rep` carries its `signalTrace`. That is what makes a bad count debuggable
after the fact instead of unreproducible.

---

## 13. Persistence

**GRDB.** Not SwiftData.

The workload is workouts → sets → reps with timestamps and heavy aggregation, and
SwiftData has two gaps that hit it directly: `#Predicate` cannot push aggregates
down to SQL, so there is no `GROUP BY`, sum or average at the storage layer ⟨A15⟩,
and there is no CloudKit shared-database support, alongside reported sync
regressions in iOS 26.0–26.1 producing duplicate records and stale reads. ⟨A16⟩
`ModelActor` is also reported to still sometimes run code on the main thread.
⟨A17⟩ Throughput differences are large — one benchmark puts GRDB 10–20× faster on
insert-heavy work, 50k rows in 0.82 s versus 19.15 s. That traces to a single
source, so treat the multiplier as approximate and the direction as reliable.
⟨A16⟩

If CloudKit sync is wanted later, Point-Free's SQLiteData sits on GRDB and adds
sync including sharing ⟨A16⟩ — the migration path stays open without paying for it
now.

**HealthKit.** There is no quantity type for repetitions; none of Apple's
identifiers cover rep counts. ⟨A18⟩ So reps live in GRDB, and what goes to
HealthKit is the workout itself via `HKWorkoutSession` — now first-class on iOS,
not watchOS-only ⟨A18⟩ — with duration and active energy, which is enough to land
in Fitness and contribute to the Move ring. Rep detail attaches as custom
metadata, which Apple's own UI will not surface, and that is fine.

---

## 14. Interface

### 14.1 Direction

One idea, executed properly: **the screen is an instrument, not a dashboard.**
During a set there is exactly one thing worth looking at, and it is not a rep
count — it is how much velocity you have left before the set should stop.

Palette. One dominant, one accent, one neutral, per the house rule.

| Role | Value | Use |
|---|---|---|
| Ground | `#121110` warm near-black | Full-bleed behind live video; UI chrome |
| Type | `#F2EDE4` bone | All text, all iconography |
| Accent | `#B4472E` oxide | Exactly one meaning: **stop the set** |

The velocity bar carries its information through **length**, not hue. It sits
bone-coloured for the whole set and saturates to oxide only when velocity loss
crosses the block's cutoff. One colour, one meaning, no traffic-light gradient
and no decorative status dots. Rep count is large but secondary; ROM percentage is
tertiary and appears in the set summary rather than live.

One typeface, two weights. SF Pro, bold for the numerals, regular for everything
else. SF Symbols for icons, consistent stroke weight. No emoji anywhere.

Camera overlay is a thin bone skeleton at low opacity and, on Track A, the plate's
fitted ellipse with the bar path trailing behind it in the sagittal plane. The bar
path is the one genuinely beautiful thing this app draws and it should be the
thing people screenshot.

### 14.2 Rendering

SwiftUI `Canvas`, redrawn only when new tracker output arrives — not on a
`CADisplayLink`. A 17–33 point skeleton is a trivial draw-call count and is not
the frame budget. `Canvas` under *continuous* animation-driven redraw has a
reported energy and thermal cost ⟨A19⟩, which is precisely why redraw is gated on
data arrival. Inference runs below capture rate, so hold the last skeleton
between updates rather than interpolating.

### 14.3 Setup and framing

Camera-angle error is the documented top failure mode, with accuracy degrading
past roughly 30° off-perpendicular, and the mitigation that reportedly works is
an on-screen placement guide that enforces it. ⟨A11⟩ So:

- A framing overlay at setup showing the required capture box, with live
  pass/fail on full-body visibility.
- Explicit warnings on backlighting and low light, both of which drop landmark
  confidence.
- **Plate visibility check** before a loaded set: if no plate of the configured
  diameter is detected, say so, because Track A is about to be unavailable and
  the user should know before the set, not after.
- Save the framing per exercise so the second session doesn't re-negotiate it.

### 14.4 Feedback

Screen-only in v1, per decision. Two notes for when that changes:

Audio would need `[.mixWithOthers, .duckOthers]` and, critically, an explicit
`setActive(false)` in the player's completion callback — the well-documented
failure is apps that duck and never restore, leaving Spotify permanently quiet.
⟨A20⟩ And use pre-rendered clips rather than `AVSpeechSynthesizer`, which routes
through an accessibility audio graph on real hardware that degrades voice quality
in a way the Simulator hides. ⟨A21⟩

Haptics are near-useless here and should not be built. The Taptic Engine vibrates
the chassis, and the phone is propped against something two metres away. ⟨A22⟩

---

## 15. Evaluation harness

**Milestone 0. Before the app.**

A command-line target in the same Xcode project, sharing the exact tracker,
counter and Tim Method code the app uses. One implementation of the algorithm, not
two — this is why it is Swift and not Python.

```
timmethod-eval \
  --fixtures ./fixtures \
  --provider apple-vision-3d \
  --report ./out/report.json
```

For every fixture clip with a ground-truth count it reports predicted vs actual,
per-clip and aggregate MAE, off-by-one accuracy, false-positive and
false-negative reps, and where in the signal each disagreement occurred. Fixtures
are `.mov` plus a sidecar JSON of ground truth. `ReplayFrameSource` (§5) feeds
them through the production path.

The provider flag is what makes §4.1 a decision rather than a guess: run the same
fixtures through Apple Vision and MediaPipe and read the numbers.

### 15.1 Fixture sources

Given the constraint of not recording en masse:

| Source | Content | Licence | Use |
|---|---|---|---|
| **FLEX** | 20 weight-loaded exercises, **evenly split barbell/dumbbell**, 38 subjects, 5 camera angles, 7,500+ multi-view recordings, RGB + 3D pose ⟨C2⟩ | CC BY-NC-SA 4.0, academic request form | **Primary.** Closest match to v1 scope that exists |
| **MM-Fit** | 10 exercises, 5 dumbbell; multimodal with 2D/3D pose and rep labels ⟨C2⟩ | Open download, no commercial restriction stated | Secondary, dumbbell coverage |
| **Fitness-AQA** | Back squat, overhead press, barbell row, form-error labelled ⟨C2⟩ | Non-commercial, gated | Form-flag validation |
| **InfiniteRep** | 1,000 synthetic videos, 10 bodyweight exercises, varied avatars and lighting ⟨A23⟩ | CC BY 4.0, commercially clean | Bodyweight track, lighting sweeps |
| **RepCount-A** | 1,041 videos, 19,280 rep annotations ⟨A23⟩ | No explicit licence found — verify before any commercial use | Counting stress-test |
| **Your clips** | Incremental, added over time | — | The failure modes synthetic data can't produce |

Note the licence asymmetry honestly: FLEX and Fitness-AQA are non-commercial. That
is the correct licence for a personal build and becomes a blocker the day this
ships. Record replacements before that day, not on it.

The clips only you can provide, when you get to it: baggy hoodie (no runtime fix
for clothing exists in the literature ⟨A24⟩), your actual gym lighting, your rack
and its uprights, deliberate partial reps, a set taken to genuine failure so ROM
visibly collapses, and one set where you walk out of frame mid-set and come back.

### 15.2 Targets

| Metric | Target | Floor |
|---|---|---|
| Count MAE, loaded, plate visible | ≤ 0.05 | ≤ 0.15 |
| Off-by-one accuracy, loaded | ≥ 98% | ≥ 95% |
| Count MAE, bodyweight | ≤ 0.15 | ≤ 0.35 |
| False-positive reps per session | 0 | ≤ 1 |
| Mean concentric velocity RMSE | ≤ 0.05 m/s | ≤ 0.10 m/s |
| Set-boundary detection F1 | ≥ 0.95 | ≥ 0.90 |

The velocity target is set against what has actually been achieved from a phone
camera: 0.01–0.04 m/s RMSE versus Vicon. ⟨B2⟩ It is a real bar, and it has been
cleared before.

---

## 16. Performance and thermals

| Metric | Target | Floor |
|---|---|---|
| Capture | 60 fps | 30 fps |
| Plate detection | every frame, ≤ 5 ms | every 2nd frame |
| Pose inference | every 2nd frame, ≤ 20 ms | every 4th frame |
| Camera → screen | ≤ 120 ms | ≤ 250 ms |

Sustained camera plus ML is among the most thermally hostile things a phone does;
iOS visibly lowers frame rates under serious thermal load. ⟨A25⟩ For a 45-minute
session, hitting `.serious` is the normal case, not the exception. Observe
`ProcessInfo.thermalState` from day one.

```
.nominal  → full pipeline
.fair     → pose every 4th frame; plate detection unchanged
.serious  → 30 fps capture; pose off unless the exercise needs it;
            plate track alone still counts and still measures velocity
.critical → counting continues on plate track; preview dims; overlay off
```

The graceful-degradation story is a direct payoff of the two-track architecture:
the cheap track is also the accurate one for loaded work, so thermal throttling
costs you the skeleton overlay and form flags, never the rep count.

Prefer `.cpuAndNeuralEngine` for any Core ML compute units. Never
`isIdleTimerDisabled` without a matching re-enable on session end.

---

## 17. Privacy and store readiness

Built to store standard from the start, whether or not it ships.

- **On-device only.** No frame leaves the device, no frame persists beyond the
  in-memory buffer for the current inference. Clip saving, if ever added, is
  explicit opt-in per clip.
- `NSCameraUsageDescription` must be specific — generic strings draw ITMS-90738.
  ⟨A26⟩ Copy: *"Tim Method uses your camera to measure how far and how fast the
  weight moves, so it can count your reps and track your range of motion. Video is
  processed on your iPhone and never leaves it."*
- `PrivacyInfo.xcprivacy` with required-reason declarations. Missing ones throw
  ITMS-91053 and block upload outright. ⟨A26⟩ Expect to declare UserDefaults, file
  timestamp, and disk space APIs.
- **Guideline 2.5.14**: a persistent on-screen indicator while the camera is
  active. ⟨A9⟩ With a camera running for a whole workout this is not optional, and
  it should be part of the visual design rather than bolted on.
- **Guideline 5.1.3(i) and 5.1.2(vi)**: health, fitness and body-pose-derived
  data may not be used for advertising, marketing or data mining, including by
  third parties. ⟨A9⟩ No analytics SDK touches set data.
- **Guideline 1.4.1**: any accuracy claim needs disclosed methodology. ⟨A9⟩ Hence
  §18 — an in-app page stating what is measured, how, and with what error.

### 17.1 The honesty page

Ships in v1, in Settings, because the whole thesis is measurement discipline:

- What velocity loss estimates and what it doesn't. The CV numbers (15–22% bench,
  26–34% squat ⟨B7⟩) stated plainly.
- Why no 1RM estimate. The systematic overestimation finding. ⟨B9⟩
- Why ROM is a percentage of your own range and not degrees. The ≥21.5° elbow
  error. ⟨A4⟩
- Why no tempo coaching and no lengthened-partials coaching, with the numbers.
- Which claims in the training layer are contested (§11.3 frequency, §11.4 rest)
  and which are solid.

---

## 18. Milestones

**M0 — Harness.** `FrameSource`, `ReplayFrameSource`, CLI target, fixture format,
FLEX and InfiniteRep pulled and converted. Nothing renders yet. Ends when a
placeholder counter can be scored against real clips.

**M1 — Track A.** Plate detection, ellipse fit, metric scale, centroid tracking,
`RepSignal` from displacement. Scored on FLEX barbell clips. Ends when count MAE
on loaded lifts clears the floor.

**M2 — Counter.** Zero-crossing, amplitude gate, ratcheting calibration, partial
classification. Tuned against fixtures only. Ends when it clears target, not
floor.

**M3 — Velocity.** Mean concentric velocity, VL% per set, RIR bands. Scored
against FLEX where reference velocity exists.

**M4 — Track B.** `PoseProvider`, Apple Vision 3D, PCA projection, posture gate,
confidence gating, subject lock. **Then the bake-off**: same fixtures through
MediaPipe, and §4.1 gets decided by data.

**M5 — App shell.** Capture actor, live preview, `Canvas` overlay, framing guide,
the velocity instrument, thermal ladder.

**M6 — Sessions.** GRDB schema, set segmentation, session history, HealthKit
workout write.

**M7 — Tim Method engine.** Volume ledger, progression rule, deload flag, honesty
page.

**M8 — Enrollment.** Few-shot template capture, DTW recognition, user-added
exercises.

**M9 — Onboarding.** Framing tutorial, plate configuration, privacy copy,
`PrivacyInfo.xcprivacy`, camera-active indicator.

M0 through M3 have no UI at all. That is deliberate: the counter is the product,
and building it against fixtures is roughly a hundred times faster than building
it against your own body.

---

## 19. Open questions

Tracked honestly rather than buried.

1. **Apple Vision vs MediaPipe accuracy.** No published comparison exists. M4
   answers it for our fixtures only.
2. **Does Apple Vision filter internally?** Undocumented. Measure static-subject
   jitter before adding any smoothing.
3. **Plate detection under gym lighting.** Chrome plates under fluorescents may
   defeat gradient-based ellipse fitting. Untested. Fallback is a one-time
   coloured band on the plate, which is exactly the marker friction §8 rejects,
   so it is a last resort.
4. **Bench press.** Plate tracking should work where pose fails, but nobody has
   published a single-camera bench solution of any kind. ⟨B5⟩ Treat as unproven
   until M1 scores it.
5. **Dumbbell end-cap tracking.** Hex dumbbells aren't circular. Round-headed ones
   are. Unresolved for hex; possibly pose-track-only.
6. **Fatigue ROM drift.** The ratchet (§7.3) is engineering judgment. No shipped
   mitigation is documented anywhere ⟨A13⟩, so there is no prior art to check it
   against. Validate on a to-failure fixture.
7. **Streaming DTW.** No subsequence/online DTW rep-counting work exists in the
   literature ⟨A14⟩. §9.3 sidesteps it by classifying completed cycles only.
8. **Apple Watch.** Deferred, not dismissed. Wrist IMU plus vision would resolve
   exactly the cases vision fails at — occluded joints, fast reps, off-axis
   camera — and the few-shot rep-counting results that transfer best to §9.3 are
   IMU-based ⟨C5⟩. The single-wrist limitation is real. Revisit after M7.
9. **Licence swap before any distribution.** FLEX and Fitness-AQA are
   non-commercial. If this ever ships, the fixture set needs rebuilding from
   InfiniteRep, MM-Fit and your own clips.

---

## 20. Sources

**A — Platform, pipeline, prior art**
A1 MediaPipe iOS: [releases](https://github.com/google-ai-edge/mediapipe/releases) · [SPM request #5464](https://github.com/google-ai-edge/mediapipe/issues/5464) · [empty worldLandmarks on iOS #5686](https://github.com/google-ai-edge/mediapipe/issues/5686) · [GPU memory #6223](https://github.com/google-ai-edge/mediapipe/issues/6223)
A2 [Apple App Store device adoption](https://developer.apple.com/support/app-store/)
A3 [Identifying 3D human body poses](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images) · [DetectHumanBodyPose3DRequest](https://developer.apple.com/documentation/vision/detecthumanbodypose3drequest)
A4 Rode et al., *Sci Rep*, Nov 2025 — [PMC12589393](https://pmc.ncbi.nlm.nih.gov/articles/PMC12589393/)
A5 [pose_landmark_filtering.pbtxt](https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/modules/pose_landmark/pose_landmark_filtering.pbtxt)
A6 [TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) · [RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator)
A7 [Swift Forums: AVFoundation + Swift 6](https://forums.swift.org/t/avfoundation-swift-6/74229) · [Fatbobman, camera app refactor](https://fatbobman.com/en/posts/swift6-refactoring-in-a-camera-app/)
A8 [ANE vs GPU sustained load](https://rockyshikoku.medium.com/iphone-on-device-llm-the-gpu-wins-the-sprint-the-neural-engine-wins-the-marathon-ce34839774a2)
A9 [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) · [AVAssetReader replay, Apple forums](https://developer.apple.com/forums/thread/652054)
A10 NEX Team, [US11450010B2](https://patents.google.com/patent/US11450010B2/en)
A11 [On-device pose estimation in production](https://dev.to/benjamin_pires_59127eddff/on-device-pose-estimation-on-ios-what-actually-works-in-production-not-just-research-papers-48ma) · [JMIR mHealth camera-angle study](https://mhealth.jmir.org/2026/1/e82412)
A12 [arXiv 2510.20012](https://arxiv.org/pdf/2510.20012)
A13 [USPTO 12020511](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12020511) (rate drift only; ROM drift undocumented)
A14 PoseSync, [arXiv 2308.12600](https://arxiv.org/abs/2308.12600)
A15 [SwiftData storage engine / aggregates](https://blakecrosley.com/blog/swiftdata-performance-storage-engine)
A16 [iOS databases 2026](https://fractal-dev.com/blog/ios-databases) · [SQLiteData](https://github.com/pointfreeco/sqlite-data)
A17 [Michael Tsai, SwiftData in 2026](https://mjtsai.com/blog/2026/06/23/swiftdata-in-appleos-27/)
A18 [HKWorkoutSession](https://developer.apple.com/documentation/healthkit/hkworkoutsession) · [WWDC25 322](https://developer.apple.com/videos/play/wwdc2025/322/)
A19 [Canvas thermal report](https://developer.apple.com/forums/thread/756273)
A20 [audio_session #66](https://github.com/ryanheise/audio_session/issues/66)
A21 [AVSpeechSynthesizer on real hardware](https://medium.com/@info_4533/why-avspeechsynthesizer-sounds-terrible-on-real-iphones-eb4565862ea8)
A22 Physical reasoning, no citation. Flagged as judgment.
A23 [RepCount-A](https://svip-lab.github.io/dataset/RepCount_dataset.html) · [InfiniteRep](https://github.com/toinfinityai)
A24 [arXiv 2212.04820](https://arxiv.org/abs/2212.04820)
A25 [Thermal throttling in real-time AR](https://hackernoon.com/what-happens-when-you-max-out-an-iphone-thermal-throttling-in-real-time-ar) (snippet only, 403 on full fetch)
A26 [ITMS-91053](https://www.avanderlee.com/xcode/missing-api-declaration-required-reason-itms-91053/) · [Apple privacy manifest notice](https://developer.apple.com/news/?id=3d8a9yyh)

**B — VBT, occlusion, depth**
B1 Bao, Liu, Huang, Liu, Wang 2026, *Front Physiol*, network meta-analysis, 27 RCTs / 694 participants — [42454076](https://pubmed.ncbi.nlm.nih.gov/42454076/)
B2 Renner, Mitter, Baca 2024, *PLOS ONE* 19(11):e0313919 — [doi](https://doi.org/10.1371/journal.pone.0313919)
B3 Bardella et al. 2017, *Sports Biomechanics* — [27414395](https://pubmed.ncbi.nlm.nih.gov/27414395/)
B4 [TrueDepth range case study](https://labs.laan.com/casestudies/truedepth-3d-scanning-case-study) · [Apple LiDAR 5 m](https://www.apple.com/newsroom/2020/03/apple-unveils-new-ipad-pro-with-lidar-scanner-and-trackpad-support-in-ipados/) · [activeDepthDataFormat](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activedepthdataformat)
B5 [pose-estimation-for-powerlifting](https://github.com/03y/pose-estimation-for-powerlifting) · [Iron Path](https://www.theironpath.com/) · [Roboflow barbell datasets](https://universe.roboflow.com/yolo-project-c2bfs/barbells-detector)
B6 [WWDC26 session 283](https://developer.apple.com/videos/play/wwdc2026/283/)
B7 Rodríguez-Rosell et al. 2020, *JSCR* 34(9):2537–2547 — [31045753](https://pubmed.ncbi.nlm.nih.gov/31045753/)
B8 Miras-Moreno et al. 2025, *IJSPP* — [39837320](https://pubmed.ncbi.nlm.nih.gov/39837320/)
B9 LeMense et al. 2024, *JSCR* 38(3):612–619 — [38416447](https://pubmed.ncbi.nlm.nih.gov/38416447/)
B10 González-Badillo & Sánchez-Medina 2010, via [vbtcoach.com](https://vbtcoach.com/blog/velocity-based-training-devices-buyers-guide)

**C — Recognition, datasets, models**
C1 [Ultralytics CoreML](https://docs.ultralytics.com/integrations/coreml) · [licence](https://www.ultralytics.com/license) · [MMAction2 skeleton zoo](https://mmaction2.readthedocs.io/en/latest/model_zoo/skeleton.html)
C2 [FLEX](https://haoyin116.github.io/FLEX_Dataset/) / [arXiv 2506.03198](https://arxiv.org/html/2506.03198) · [MM-Fit](https://mmfit.github.io/) · [Fitness-AQA](https://github.com/ParitoshParmar/Fitness-AQA)
C3 [MMPose](https://github.com/open-mmlab/mmpose)
C4 [A Short Note on Evaluating RepNet, arXiv 2411.08878](https://arxiv.org/pdf/2411.08878) · [ESCounts, arXiv 2403.18074](https://arxiv.org/abs/2403.18074)
C5 [Few-shot rep counting, arXiv 2410.00407](http://arxiv.org/abs/2410.00407) · [ExerSense, arXiv 2004.10026](http://arxiv.org/abs/2004.10026) · [JEANIE, arXiv 2402.04599](https://arxiv.org/abs/2402.04599)
C6 [MM-Fit UbiComp 2020](https://vradu.uk/publications/UbiComp2020.pdf)
C7 [Create ML action classifier](https://developer.apple.com/documentation/createml/creating-an-action-classifier-model)

**D — Training science**
D1 Robinson, Pelland, Remmert, Refalo, Jukic, Steele, Zourdos 2024, *Sports Med* 54(9):2209–2231 — [38970765](https://pubmed.ncbi.nlm.nih.gov/38970765/)
D2 Refalo et al. 2023, *Sports Med* 53(3):649–665 — [36334240](https://pubmed.ncbi.nlm.nih.gov/36334240/)
D3 Grgic, Schoenfeld, Orazem, Sabol 2021, *J Sport Health Sci* — [33497853](https://pubmed.ncbi.nlm.nih.gov/33497853/)
D4 Vieira et al. 2021, *JSCR* — [33555822](https://pubmed.ncbi.nlm.nih.gov/33555822/)
D5 Pareja-Blanco et al. 2017, *Scand J Med Sci Sports* — [27038416](https://pubmed.ncbi.nlm.nih.gov/27038416/) · 2020, *MSSE* — [32049887](https://pubmed.ncbi.nlm.nih.gov/32049887/)
D6 Pelland et al. 2026, *Sports Med* 56(2):481–505 — [41343037](https://pubmed.ncbi.nlm.nih.gov/41343037/) · [SportRxiv preprint](https://sportrxiv.org/index.php/server/preprint/view/460)
D7 Schoenfeld, Ogborn, Krieger 2017, *J Sports Sci* — [27433992](https://pubmed.ncbi.nlm.nih.gov/27433992/)
D8 Barbalho et al. 2020 — [RETRACTED](https://pubmed.ncbi.nlm.nih.gov/32804467/)
D9 Remmert et al. 2025 — [SportRxiv 537](https://sportrxiv.org/index.php/server/preprint/view/537)
D10 Schoenfeld, Grgic, Krieger 2019, *J Sports Sci* — [30558493](https://pubmed.ncbi.nlm.nih.gov/30558493/)
D11 Davidson & Barillas 2025, preprint — [medRxiv](https://www.medrxiv.org/content/10.1101/2025.09.22.25336351v2)
D12 Schoenfeld et al. 2016, *JSCR* 30(7):1805–1812 — [journal](https://journals.lww.com/nsca-jscr/fulltext/2016/07000/longer_interset_rest_periods_enhance_muscle.3.aspx)
D13 Singer et al. 2024, *Front Sports Act Living* — [article](https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2024.1429789/full)
D14 Longo et al. 2022, *JSCR* — [35622106](https://pubmed.ncbi.nlm.nih.gov/35622106/)
D15 Schoenfeld, Ogborn, Krieger 2015, *Sports Med* 45(4):577–585 — [25601394](https://pubmed.ncbi.nlm.nih.gov/25601394/)
D16 Amdi & King 2025, *J Sports Sci* — [40692176](https://pubmed.ncbi.nlm.nih.gov/40692176/)
D17 McLeod et al. 2024, umbrella review, *J Sport Health Sci* — [37385345](https://pubmed.ncbi.nlm.nih.gov/37385345/)
D18 ACSM Position Stand 2026 — [41843416](https://pubmed.ncbi.nlm.nih.gov/41843416/)
D19 Pallarés et al. 2021, *Scand J Med Sci Sports* 31(10):1866–1881 — [34170576](https://pubmed.ncbi.nlm.nih.gov/34170576/)
D20 Wolf et al. 2023, *Int J Strength Cond* — [journal](https://journal.iusca.org/index.php/Journal/article/view/182)
D21 Gschneidner et al. 2025, *J Sports Sci*, n=297 — [41055237](https://pubmed.ncbi.nlm.nih.gov/41055237/)
D22 Varovic, Wolf, Schoenfeld et al. 2025, *Int J Sports Med* 46(14):1027–1036 — [40570881](https://pubmed.ncbi.nlm.nih.gov/40570881/)
D23 Wolf et al. 2025, *PeerJ* — [39959841](https://pubmed.ncbi.nlm.nih.gov/39959841/)
D24 Kassiano et al. 2023, *JSCR* 37(5):1135–1144 — [36662126](https://pubmed.ncbi.nlm.nih.gov/36662126/)
D25 Grgic et al. 2017, *PeerJ* — [28848690](https://pubmed.ncbi.nlm.nih.gov/28848690/)
D26 Afonso et al. 2019, *Front Physiol* — [31440169](https://pubmed.ncbi.nlm.nih.gov/31440169/)
D27 No primary research isolating double progression. Expert heuristic.
D28 Dorrell et al. 2020, *JSCR*
D29 [Lyle McDonald, genetic muscular potential](https://bodyrecomposition.com/muscle-gain/genetic-muscular-potential) — %BW framing is Aragon's, commonly misattributed
D30 Ahtiainen et al. 2016, *Age (Dordr)*, n=287 — [PMC5005877](https://pmc.ncbi.nlm.nih.gov/articles/PMC5005877/)
