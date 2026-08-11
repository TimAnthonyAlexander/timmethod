# W6-02 · LiveFrameSource

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W6-01, W1-02
**Spec:** §4.2

## Goal
The real camera, satisfying the same protocol the replay source does.

## Why
Everything downstream is already built and scored against fixtures. This just swaps the source.

## Do
- [ ] `AVCaptureVideoDataOutput`, 1920×1080, 60fps, `32BGRA`
- [ ] `alwaysDiscardsLateVideoFrames = true` — drop, never queue
- [ ] Front camera default; rear + LiDAR as a configurable option
- [ ] **Do not request TrueDepth depth** — usable range is ≤1 m and framing needs 2–3 m
- [ ] Orientation via `videoRotationAngle` and `RotationCoordinator`, KVO-observing `videoRotationAngleForHorizonLevelPreview`/`Capture`
- [ ] Front-camera mirroring handled correctly alongside rotation — no worked example exists publicly, so test it
- [ ] Exposure/focus: leave continuous by default; add locking behind a flag and measure whether it helps

## Done when
- [ ] Portrait capture arrives upright on both cameras
- [ ] Sustained 60fps confirmed on the dev device
- [ ] The same counter code produces the same counts live as it does on a recording of the same set

## Notes
Exposure locking is unverified as a real practice — the APIs exist and the rationale is plausible, but no source shows real pose apps doing it. Test rather than assume. There are also reports of `videoRotationAngle` behaving differently on iPhone 17, so verify on the actual device.
