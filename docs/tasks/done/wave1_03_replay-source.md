# W1-03 · ReplayFrameSource

**Wave:** 1 — Foundations & Harness
**Status:** done
**Depends on:** W1-02
**Spec:** §5, §15

## Goal
Feed a `.mov` file through the production path frame by frame, with correct timestamps.

## Why
The Simulator has no camera in 2026. Replay is the only way to iterate without standing up, and it is the substrate the eval harness runs on.

## Do
- [ ] `AVAssetReader` + `AVAssetReaderTrackOutput`, `copyNextSampleBuffer()` loop
- [ ] Output `32BGRA` to match the live pipeline exactly
- [ ] Preserve real presentation timestamps — do not synthesise a uniform clock, since fixture clips vary in frame rate
- [ ] Optional `--realtime` pacing flag; default is as-fast-as-possible for batch scoring
- [ ] Handle rotation metadata so portrait fixtures arrive upright

## Done when
- [ ] A known 10-second 60fps clip yields ~600 frames with monotonic timestamps
- [ ] Frame content matches the source visually (spot-check one dumped frame)
- [ ] Runs on macOS in the CLI target

## Notes
Apple-endorsed pattern; an Apple media engineer describes it on the developer forums and the "Action & Vision" sample ships a dual live/file capture controller.
