# W1-01 · Xcode project skeleton

**Wave:** 1 — Foundations & Harness
**Status:** open
**Depends on:** —
**Spec:** §4.3, §4.4

## Goal
A buildable Xcode project with the four targets the whole plan rests on, compiling clean under Swift 6 strict concurrency.

## Why
Every later wave assumes the core logic lives in a library that both the app and a headless CLI can import. Getting that split wrong on day one means the harness ends up duplicating the algorithm, which is the exact failure §15 exists to prevent.

## Do
- [ ] New Xcode project, iOS 26.0 deployment target, Swift 6.3
- [ ] Target `TimMethodCore` — SPM library, no UIKit/SwiftUI import, all tracking/counting/engine code
- [ ] Target `TimMethod` — the app, imports Core
- [ ] Target `timmethod-eval` — macOS command-line tool, imports Core
- [ ] Target `TimMethodCoreTests` — swift-testing
- [ ] `SWIFT_STRICT_CONCURRENCY = complete` on every target
- [ ] `.gitignore`, `.swiftformat` or equivalent, one CI-less `make check` script that builds and tests

## Done when
- [ ] `swift build` and `xcodebuild test` both pass with zero concurrency warnings
- [ ] `TimMethodCore` has no dependency on AVFoundation-app-only or SwiftUI symbols
- [ ] The CLI target runs and prints usage

## Notes
Core must stay importable from a macOS CLI. That rules out `UIApplication` and friends leaking into it. AVFoundation itself is fine — `AVAssetReader` works on macOS.
