# W6-01 · Capture actor

**Wave:** 6 — App Shell
**Status:** open
**Depends on:** W1-02
**Spec:** §4.4

## Goal
A global actor owning the capture session, with actor isolation aligned to the serial queue AVFoundation already requires.

## Why
This is the single most-reported friction point in the Swift 6 ecosystem and it will not be fixed for us. Getting the shape right once means never fighting it again.

## Do
- [ ] `@globalActor actor CaptureActor` backed by a custom `SerialExecutor` / `UnownedSerialExecutor` wrapping the serial `DispatchQueue`, so isolation and queue identity are the same thing and there is no extra hop
- [ ] The `AVCaptureVideoDataOutputSampleBufferDelegate` conformer is a **private nested class living entirely inside the actor**
- [ ] Raw buffers never escape the actor. Only `Sendable` value types cross to `@MainActor`
- [ ] Results out via `AsyncStream`, not `@Published` (not isolation-safe inside an actor)
- [ ] `@preconcurrency import AVFoundation` documented at exactly one place, with the reason

## Done when
- [ ] Compiles with strict concurrency and no `@unchecked Sendable` beyond the documented `TimedFrame` case
- [ ] No `CVPixelBuffer` reference is reachable from `@MainActor` code
- [ ] `AVCaptureVideoPreviewLayer` ownership is resolved and the approach is documented

## Notes
Preview layer ownership (wants `@MainActor`, fights isolation) is flagged as an unresolved pain point in the wild. Expect to spend real time here and write down whatever you land on.
