# W5-02 · Apple Vision 3D provider

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-01
**Spec:** §4.1

## Goal
`DetectHumanBodyPose3DRequest` behind the protocol. The default implementation.

## Why
Zero dependency, ANE-backed, and it supplies the metric hip-origin coordinates the angle math needs. It starts as default on integration cost and thermal behaviour, which are evidenced, not on accuracy, which is unmeasured.

## Do
- [ ] `DetectHumanBodyPose3DRequest`, iOS 18+ API, 17 joints
- [ ] Map `cameraRelativePosition` / `cameraOriginMatrix` into the canonical world-coordinate frame
- [ ] Read `bodyHeight` and its `heightEstimationTechnique` — set `ScaleSource.lidarBodyHeight` only when `.measured`, otherwise `.referenceHeight`
- [ ] Verify empirically which `CGImagePropertyOrientation` is correct for our portrait capture; community samples disagree
- [ ] Measure and record static-subject jitter (feeds W3-01's smoothing decision)

## Done when
- [ ] Landmarks arrive in metres with a hip origin, verified against a known pose
- [ ] `ScaleSource` correctly distinguishes measured from fallback height
- [ ] Inference latency measured on the dev device and recorded

## Notes
`bodyHeight` returns a *measured* value only when the session uses the LiDAR camera; otherwise Apple substitutes a fixed 1.8 m reference. That fallback silently injects a proportional error into everything downstream, which is exactly why `ScaleSource` exists.
