# W5-07 · MediaPipe provider (challenger)

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W5-01
**Spec:** §4.1

## Goal
The second implementation, purely so the bake-off has something to compare.

## Why
MediaPipe has genuine advantages worth measuring: 33 landmarks including feet and hands, and BlazePose-Heavy posted the best pure-3D error (146 mm MPJPE) in the one benchmark that exists.

## Do
- [ ] Add CocoaPods for this one dependency — there is still no official SPM support (request open and unanswered since June 2024)
- [ ] `MediaPipeTasksVision`, `runningMode = .liveStream`, `detectAsync(image:timestampInMilliseconds:)`
- [ ] Feed `CVPixelBuffer` directly via `MPImage` — no manual conversion needed
- [ ] Map `worldLandmarks` (metres, mid-hip origin) into the canonical frame; **verify axis directions empirically**, they are not documented
- [ ] **Verify `visibility` and `presence` are actually populated** before relying on them
- [ ] CPU delegate, not GPU
- [ ] Measure the real IPA size delta

## Done when
- [ ] Landmarks arrive and map correctly, verified against a known pose
- [ ] Confidence values are confirmed populated or confirmed nil, and recorded either way
- [ ] IPA size delta measured and written into the bake-off report

## Notes
Three known risks, all confirmed in the wild. The pod `-force_load`s a 430 MB unstripped archive, pulling in every vision task whether used or not and defeating dead-stripping. `visibility`/`presence` have a long history of returning nil, including an iOS-specific report of empty `worldLandmarks`. And the GPU delegate has open memory-growth and crash reports on long camera sessions — hence CPU.
