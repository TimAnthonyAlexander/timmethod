# W1-02 · FrameSource protocol

**Wave:** 1 — Foundations & Harness
**Status:** done
**Depends on:** W1-01
**Spec:** §5

## Goal
One protocol that both the live camera and a video file satisfy, so nothing downstream knows which it is talking to.

## Why
This is the seam that makes the entire pipeline testable headlessly. Without it, tuning the counter means doing squats between parameter changes.

## Do
- [ ] `protocol FrameSource: Sendable` with `var frames: AsyncStream<TimedFrame>`, `start()`, `stop()`
- [ ] `struct TimedFrame` carrying `CVPixelBuffer`, `CMTime`, optional `AVDepthData`
- [ ] Document the single `@unchecked Sendable` exception on `TimedFrame` with a comment explaining why buffers can't cross actors safely and what invariant makes it acceptable here
- [ ] Backpressure policy: the stream drops oldest on overflow, never buffers unboundedly

## Done when
- [ ] Protocol compiles under strict concurrency with exactly one documented `@unchecked` annotation
- [ ] A stub implementation emitting synthetic frames drives a consumer in a unit test

## Notes
`CVPixelBuffer` and `CMSampleBuffer` are still not `Sendable` in 2026 and `@preconcurrency import CoreVideo` does not silence it. Apple's own AVCam sample fails strict checking without `@preconcurrency import AVFoundation`. This is not fixable, only containable.
