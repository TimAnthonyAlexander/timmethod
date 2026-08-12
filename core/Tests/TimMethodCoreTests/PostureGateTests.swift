import Foundation
import Testing

@testable import TimMethodCore

/// **All verification in this file is synthetic** — hand-constructed
/// `PostureGate.FrameInput` traces standing in for a plate-track's axial /
/// lateral projections, matching `MotionAxisTests`' and `PlateTrackerTests`'
/// precedent, not real footage. Real-footage confirmation of SPEC §7.1's
/// Done-whens ("a fixture containing setup, a set, and racking counts only
/// the set's reps"; "a fixture of someone walking past the camera counts
/// zero") is W3-06's job, once W1-06's fixture corpus exists. Nothing here
/// claims a real-footage result.
///
/// Every trace here exercises **Track A cues only** — `FrameInput.pose` is
/// always `nil`. The pose seam (`PostureGate.PoseCueContribution`) has no
/// producer anywhere in this codebase yet (Wave 5), so there is nothing to
/// test there beyond the type compiling and being usable as an input field —
/// see `PostureGate`'s own doc comment for why that split is deliberate.
@Suite("PostureGate")
struct PostureGateTests {
    // MARK: - Shared fixture constants

    static let plateDiameterMetres = 0.45 // Olympic/bumper, SPEC §8.
    static let sampleRateHz = 60.0 // SPEC §16 ceiling.
    static let dt = 1.0 / sampleRateHz

    static func makeConfiguration() -> PostureGate.Configuration {
        .trackA(plateDiameterMetres: plateDiameterMetres)
    }

    /// Runs `configuration` over `frames` (already-built `(t, FrameInput)`
    /// pairs, oldest first) and returns every frame's resulting `State`, in
    /// order — the same shape a real caller would fold into a per-frame
    /// trace (SPEC / this task: "gate state recorded per frame").
    static func run(_ frames: [(t: TimeInterval, input: PostureGate.FrameInput)], configuration: PostureGate.Configuration)
        -> [PostureGate.State]
    {
        var gate = PostureGate(configuration: configuration)
        return frames.map { gate.advance($0.input, t: $0.t) }
    }

    /// Index of the first frame whose state satisfies `predicate`, or `nil`.
    static func firstIndex(of states: [PostureGate.State], where predicate: (PostureGate.State) -> Bool) -> Int? {
        states.firstIndex(where: predicate)
    }

    // MARK: - Setup, a set, and racking: opens only during the set

    /// Stands in for SPEC §7.1's own worked example: someone walks a plate
    /// to the rack (large lateral motion), settles into position (stable),
    /// performs 4 reps (oscillating axial, stable lateral), then racks the
    /// plate and walks away (large lateral motion again).
    @Test("a setup → set → racking trace opens only during the set, closes during walking on both ends")
    func opensOnlyDuringTheSet() {
        let configuration = Self.makeConfiguration()
        // 2.0 m/s — fast enough that the "large lateral motion" signature is
        // unambiguous within a couple of frames (see the walking-only test's
        // derivation), not a claim about realistic gym gait.
        let walkSpeed = 2.0

        var frames: [(t: TimeInterval, input: PostureGate.FrameInput)] = []

        // Phase A: walk to the rack, [0, 2.0). Large, steadily growing
        // lateral sweep; axial flat (bootstraps the height baseline at 0).
        let phaseAEnd = 2.0
        var t = 0.0
        while t < phaseAEnd {
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: 0, lateralMetres: walkSpeed * t)))
            t += Self.dt
        }
        let lateralAtPhaseAEnd = walkSpeed * phaseAEnd

        // Phase B: settle at the rack, [2.0, 3.5). Lateral holds flat while
        // the walking history ages out of the 1 s lateral window; axial
        // stays flat.
        let phaseBEnd = 3.5
        while t < phaseBEnd {
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: 0, lateralMetres: lateralAtPhaseAEnd)))
            t += Self.dt
        }

        // Phase C: the set, [3.5, 11.5) — 4 reps at 0.5 Hz (2 s/rep), 0.30 m
        // amplitude (the same squat amplitude `MotionAxisTests` uses).
        // Lateral carries only small jitter around the settled value.
        let repFrequencyHz = 0.5
        let repAmplitude = 0.30
        let phaseCStart = phaseBEnd
        let phaseCEnd = phaseCStart + 8.0
        while t < phaseCEnd {
            let phaseT = t - phaseCStart
            let axial = repAmplitude * sin(2 * Double.pi * repFrequencyHz * phaseT)
            let lateral = lateralAtPhaseAEnd + 0.02 * sin(2 * Double.pi * 3.0 * phaseT)
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: axial, lateralMetres: lateral)))
            t += Self.dt
        }

        // Phase D: rack the plate and walk away, [11.5, 14.5). Axial back to
        // flat (racked); lateral ramps again from the settled value.
        let phaseDStart = phaseCEnd
        let phaseDEnd = phaseDStart + 3.0
        while t < phaseDEnd {
            let lateral = lateralAtPhaseAEnd + walkSpeed * (t - phaseDStart)
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: 0, lateralMetres: lateral)))
            t += Self.dt
        }

        let states = Self.run(frames, configuration: configuration)
        #expect(states.count == frames.count)

        // Never open anywhere in phase A (the walk-in never sustains a long
        // enough "plausible" streak to satisfy the open dwell — see the
        // walking-only test for the same derivation in isolation).
        for (index, frame) in frames.enumerated() where frame.t < phaseAEnd {
            #expect(!states[index].isOpen, "expected closed during the walk-in at t=\(frame.t)")
        }

        // Opens somewhere in phase B, comfortably before the set starts.
        guard let openIndex = Self.firstIndex(of: states, where: { $0.isOpen }) else {
            Issue.record("gate never opened")
            return
        }
        let openTime = frames[openIndex].t
        #expect(openTime >= phaseAEnd, "opened during the walk-in at t=\(openTime), not after it")
        #expect(openTime < phaseCStart, "opened at t=\(openTime), too late — would swallow the first rep")

        // Open for every single frame of the set — the invariant this test
        // exists to prove (SPEC §7.1 Done-when: "counts only the set's reps"
        // requires the gate to hold open, without interruption, across it).
        for (index, frame) in frames.enumerated() where frame.t >= phaseCStart && frame.t < phaseCEnd {
            #expect(states[index].isOpen, "expected open during the set at t=\(frame.t), got \(states[index])")
            #expect(states[index].reason == nil)
        }

        // Closes somewhere in phase D, well before racking-and-walk-away is over.
        guard
            let closeIndex = states.indices.first(where: { $0 > openIndex && frames[$0].t >= phaseDStart && !states[$0].isOpen })
        else {
            Issue.record("gate never closed again after racking")
            return
        }
        let closeTime = frames[closeIndex].t
        #expect(closeTime < phaseDStart + 1.5, "took too long to close after racking: t=\(closeTime)")

        // Stays closed for the remainder, with a specific reason.
        for (index, frame) in frames.enumerated() where frame.t >= closeTime {
            #expect(!states[index].isOpen, "expected closed after racking at t=\(frame.t)")
            if case .closed(.nonWorkingAxisUnstable(let range, let limit)) = states[index] {
                #expect(range > limit)
            } else {
                Issue.record("expected .nonWorkingAxisUnstable at t=\(frame.t), got \(states[index])")
            }
        }

        // Spot-check reasons during the two walking phases are specific and
        // correct, not a generic fallback.
        let midWalkInIndex = frames.firstIndex { $0.t >= 1.0 }!
        if case .closed(.nonWorkingAxisUnstable(let range, let limit)) = states[midWalkInIndex] {
            #expect(range > limit)
        } else {
            Issue.record("expected .nonWorkingAxisUnstable mid walk-in, got \(states[midWalkInIndex])")
        }
    }

    // MARK: - Walking past the camera: never opens

    @Test("a plate that's present and moving, but sweeping the non-working axis, never opens")
    func walkingPastCameraNeverOpens() {
        let configuration = Self.makeConfiguration()
        // 1 Hz, 1 m amplitude: fast enough that the lateral range statistic
        // exceeds the open threshold within ~36 ms (see derivation below),
        // well under the 150 ms open dwell, so the gate can never accumulate
        // a long enough "plausible" streak to open — not even briefly.
        //
        // Derivation: near t=0, the trailing-window range is just the raw
        // signal's own excursion from 0, i.e. `sin(2π·1·t)`. That crosses
        // the open limit (0.5 × 0.45 m = 0.225 m) at
        // `t = asin(0.225) / (2π) ≈ 0.036 s`, then keeps rising (the window
        // captures the full swing) and never revisits a value that small
        // again for the rest of the trace, so there is exactly one
        // "plausible" streak and it is far short of `defaultOpenDwellSeconds`.
        let frequencyHz = 1.0
        let amplitude = 1.0
        let duration = 3.0

        var frames: [(t: TimeInterval, input: PostureGate.FrameInput)] = []
        var t = 0.0
        while t < duration {
            let lateral = amplitude * sin(2 * Double.pi * frequencyHz * t)
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: 0, lateralMetres: lateral)))
            t += Self.dt
        }

        let states = Self.run(frames, configuration: configuration)

        for (index, frame) in frames.enumerated() {
            #expect(!states[index].isOpen, "expected never open at t=\(frame.t), got \(states[index])")
        }

        // The reason should be specific once the walking signature is
        // established (skip the very first couple of frames, before the
        // window has anything to measure a range over at all).
        let established = frames.firstIndex { $0.t >= 0.2 }!
        if case .closed(.nonWorkingAxisUnstable(let range, let limit)) = states[established] {
            #expect(range > limit)
        } else {
            Issue.record("expected .nonWorkingAxisUnstable once walking is established, got \(states[established])")
        }
    }

    // MARK: - No plate tracked: never opens

    @Test("no plate tracked, ever, never opens — reason is always .noPlateTracked")
    func noPlateNeverOpens() {
        let configuration = Self.makeConfiguration()
        var frames: [(t: TimeInterval, input: PostureGate.FrameInput)] = []
        var t = 0.0
        while t < 2.0 {
            frames.append((t, PostureGate.FrameInput(plateTracked: false)))
            t += Self.dt
        }

        let states = Self.run(frames, configuration: configuration)
        for (index, frame) in frames.enumerated() {
            #expect(states[index] == .closed(.noPlateTracked), "expected .noPlateTracked at t=\(frame.t), got \(states[index])")
        }
    }

    // MARK: - Hysteresis: hovering at a boundary does not chatter

    @Test("a signal hovering across the close threshold does not chatter: exactly one open transition")
    func hysteresisPreventsChatterAtTheBoundary() {
        // Explicit, round numbers rather than the plate-diameter-derived
        // defaults, so the boundary this test targets is easy to read
        // straight out of the test: open at 0.30 m, close at 0.45 m
        // deviation. `heightBaselineTimeConstantSeconds` is set far longer
        // than the test's own duration so the EMA baseline is effectively
        // frozen at its bootstrap value (0) — otherwise the baseline itself
        // chasing the hovering signal would confound the thing being
        // measured.
        let configuration = PostureGate.Configuration(
            openHeightDeviationLimitMetres: 0.30,
            closeHeightDeviationLimitMetres: 0.45,
            heightBaselineTimeConstantSeconds: 1000,
            openLateralRangeLimitMetres: 1.0,
            closeLateralRangeLimitMetres: 1.5
        )

        var frames: [(t: TimeInterval, input: PostureGate.FrameInput)] = []

        // Preamble: dead stationary, long enough to clear the open dwell
        // and establish the baseline at 0.
        let preambleEnd = 1.0
        var t = 0.0
        while t < preambleEnd {
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: 0, lateralMetres: 0)))
            t += Self.dt
        }

        // Hover: oscillate at 5 Hz around the close limit itself (0.45 m),
        // ±0.05 m. Each excursion above 0.45 m lasts about a tenth of a
        // second — under `closeDwellSeconds` (0.4 s) — so with hysteresis
        // this must never accumulate enough consecutive "implausible" time
        // to actually close. A single-threshold gate with no dwell would
        // instead flip open/closed roughly 10 times per second here.
        let hoverEnd = preambleEnd + 3.0
        let hoverFrequencyHz = 5.0
        while t < hoverEnd {
            let phaseT = t - preambleEnd
            let axial = 0.45 + 0.05 * sin(2 * Double.pi * hoverFrequencyHz * phaseT)
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: axial, lateralMetres: 0)))
            t += Self.dt
        }

        let states = Self.run(frames, configuration: configuration)

        // First frame: dwell hasn't elapsed yet, but every cue already
        // passes — the reason should say so specifically, not just "closed".
        if case .closed(.awaitingDwell(let elapsed, let required)) = states[0] {
            #expect(elapsed <= required)
        } else {
            Issue.record("expected .awaitingDwell on frame 0, got \(states[0])")
        }

        // Exactly one true open transition across the whole run, and never
        // closes again despite the hover crossing the close threshold
        // roughly 15 times.
        var transitions = 0
        for index in 1..<states.count where states[index].isOpen != states[index - 1].isOpen {
            transitions += 1
        }
        #expect(transitions == 1, "expected exactly 1 state transition (the initial open), got \(transitions)")

        let hoverStartIndex = frames.firstIndex { $0.t >= preambleEnd }!
        for index in hoverStartIndex..<states.count {
            #expect(states[index].isOpen, "expected to stay open through the hover at t=\(frames[index].t), got \(states[index])")
        }
    }

    // MARK: - Promptness: opens before the first rep is swallowed

    @Test("the gate opens during setup, before the first rep begins — not late enough to swallow it")
    func opensBeforeTheFirstRep() {
        let configuration = Self.makeConfiguration()

        var frames: [(t: TimeInterval, input: PostureGate.FrameInput)] = []

        // A brief, stationary "in position, about to lift" moment.
        let setupEnd = 0.3
        var t = 0.0
        while t < setupEnd {
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: 0, lateralMetres: 0)))
            t += Self.dt
        }

        // Two reps starting immediately at the setup/rep boundary.
        let repFrequencyHz = 0.5
        let repAmplitude = 0.30
        let repsEnd = setupEnd + 4.0
        while t < repsEnd {
            let axial = repAmplitude * sin(2 * Double.pi * repFrequencyHz * (t - setupEnd))
            frames.append((t, PostureGate.FrameInput(plateTracked: true, axialMetres: axial, lateralMetres: 0)))
            t += Self.dt
        }

        let states = Self.run(frames, configuration: configuration)

        guard let openIndex = Self.firstIndex(of: states, where: { $0.isOpen }) else {
            Issue.record("gate never opened")
            return
        }
        let openTime = frames[openIndex].t

        // Opens inside the setup window, i.e. strictly before the first rep
        // begins — a gate that only opened once the rep was already
        // underway would be exactly the "late gate" bug this test guards
        // against.
        #expect(openTime < setupEnd, "opened at t=\(openTime), at or after the first rep began (t=\(setupEnd))")

        // And opens close to the configured dwell, not with extra,
        // unexplained latency on top of it.
        #expect(
            openTime <= PostureGate.defaultOpenDwellSeconds + 3 * Self.dt,
            "opened at t=\(openTime), later than the configured open dwell (\(PostureGate.defaultOpenDwellSeconds)) plus a few frames' slack"
        )

        // Once open, stays open through both full reps.
        for (index, frame) in frames.enumerated() where frame.t >= openTime {
            #expect(states[index].isOpen, "expected to stay open through the reps at t=\(frame.t)")
        }
    }
}
