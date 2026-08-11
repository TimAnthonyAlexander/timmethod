# W5-01 · PoseProvider protocol

**Wave:** 5 — Track B: Pose & Bake-off
**Status:** open
**Depends on:** W1-02
**Spec:** §4.1

## Goal
One protocol, swappable backends, chosen at runtime by flag or config.

## Why
No benchmark comparing Apple Vision and MediaPipe exists anywhere. The best study in the field (Rode et al. 2025, eleven models against mocap) does not include Apple Vision at all. The only honest way to decide is to measure both on our own fixtures.

## Do
- [ ] `protocol PoseProvider: Sendable` — `func landmarks(for: TimedFrame) async throws -> PoseFrame?`
- [ ] `struct PoseFrame`: landmarks in **world coordinates** (metres, hip-origin), per-landmark confidence, timestamp, provider id
- [ ] A canonical joint enum both backends map into, so downstream code never branches on provider
- [ ] Backends declare which canonical joints they can supply (Apple 17, MediaPipe 33) and downstream degrades rather than crashes on absence

## Done when
- [ ] Two stub providers satisfy the protocol and are selectable by CLI flag
- [ ] Downstream code contains zero provider-specific branches

## Notes
The canonical mapping is where the 17-vs-33 difference gets absorbed. MediaPipe's extra feet and hands landmarks are real advantages, but only for exercises that need them — the mapping should make that a capability query, not a hard requirement.
