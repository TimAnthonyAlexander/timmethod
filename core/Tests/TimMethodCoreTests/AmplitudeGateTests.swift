import Foundation
import Testing

@testable import TimMethodCore

/// `AmplitudeGate` is a pure judge over already-assembled inputs (a
/// `ZeroCrossCounter.Candidate`, the signal samples spanning it, and the
/// posture history spanning it) — no streaming state to drive, so unlike
/// `ZeroCrossCounterTests` / `PostureGateTests` these fixtures are built by
/// hand rather than sampled from an analytic signal. That is the more
/// honest fixture shape here: every test is really asking "does this one
/// candidate, with these numbers, clear this one bar," and hand-built
/// numbers make the bar and the candidate equally legible in the test
/// itself.
@Suite("AmplitudeGate")
struct AmplitudeGateTests {

    // MARK: - Fixtures

    static func candidate(
        startT: TimeInterval, startX: Double,
        valleyT: TimeInterval, valleyX: Double,
        endT: TimeInterval, endX: Double
    ) -> ZeroCrossCounter.Candidate {
        ZeroCrossCounter.Candidate(
            startPeak: .init(t: startT, x: startX),
            valley: .init(t: valleyT, x: valleyX),
            endPeak: .init(t: endT, x: endX)
        )
    }

    /// Evenly-spaced confidence samples covering `[start, end]` inclusive.
    static func confidenceSamples(
        from start: TimeInterval, to end: TimeInterval, count: Int = 5, confidence: Double
    ) -> [RepSignal.Sample] {
        (0..<count).map { i in
            let t = count == 1 ? start : start + (end - start) * Double(i) / Double(count - 1)
            return RepSignal.Sample(t: t, x: 0, confidence: confidence)
        }
    }

    /// Posture history that is `.open` at every sampled instant across
    /// `[start, end]`.
    static func postureOpenThroughout(
        from start: TimeInterval, to end: TimeInterval, count: Int = 5
    ) -> [AmplitudeGate.PostureObservation] {
        (0..<count).map { i in
            let t = count == 1 ? start : start + (end - start) * Double(i) / Double(count - 1)
            return AmplitudeGate.PostureObservation(t: t, state: .open)
        }
    }

    /// Posture history that is open at both endpoints but closed at the
    /// exact midpoint — a dip an endpoints-only check would miss entirely.
    static func postureDippedOnlyInMiddle(
        from start: TimeInterval, to end: TimeInterval
    ) -> [AmplitudeGate.PostureObservation] {
        let mid = (start + end) / 2
        return [
            AmplitudeGate.PostureObservation(t: start, state: .open),
            AmplitudeGate.PostureObservation(t: mid, state: .closed(.noPlateTracked)),
            AmplitudeGate.PostureObservation(t: end, state: .open),
        ]
    }

    static func makeConfiguration(
        threshold: AmplitudeGate.Threshold = .metres(0.05),
        scale: RepSignal.ScaleSource = .plateDiameter(mm: 450),
        minimumMeanConfidence: Double = 0.5,
        minimumPhaseDurationSeconds: Double = 0.080
    ) throws -> AmplitudeGate.Configuration {
        try AmplitudeGate.Configuration(
            threshold: threshold, scale: scale, minimumMeanConfidence: minimumMeanConfidence,
            minimumPhaseDurationSeconds: minimumPhaseDurationSeconds)
    }

    // MARK: - Headline: fast rep, sub-150ms bottom, still accepted

    @Test("a fast rep whose phases run 100ms — under the old 150–250ms MIN_PHASE_MS — is accepted")
    func fastRepWithSubDwellBottomIsAccepted() throws {
        // Each leg is 100ms: comfortably clears the 80ms spike floor, but
        // would have been rejected outright by the dwell-based design
        // SPEC §7.2 replaces (150-250ms). Amplitude is a full 0.30m swing.
        let c = Self.candidate(startT: 0.0, startX: 0.30, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: 0.30)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.9),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.20)
        )

        #expect(outcome.isAccepted)
        guard case .accepted(let acceptance) = outcome else {
            Issue.record("expected .accepted, got \(outcome)")
            return
        }
        #expect(abs(acceptance.amplitude - 0.30) < 1e-9)
        #expect(abs(acceptance.phaseDurationSeconds - 0.10) < 1e-9)
    }

    // MARK: - Twitch below A_min

    @Test("a twitch below A_min is rejected with the amplitude reason and the actual numbers")
    func twitchBelowAMinIsRejected() throws {
        let c = Self.candidate(startT: 0.0, startX: 0.01, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: 0.01)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.9),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.20)
        )

        guard case .rejected(let rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(rejection.reasons.count == 1)
        guard case .amplitudeTooSmall(let amplitude, let descent, let ascent, let requiredAMin) = try #require(rejection.reasons.first)
        else {
            Issue.record("expected .amplitudeTooSmall, got \(rejection.reasons)")
            return
        }
        #expect(abs(amplitude - 0.01) < 1e-9)
        #expect(abs(descent - 0.01) < 1e-9)
        #expect(abs(ascent - 0.01) < 1e-9)
        #expect(abs(requiredAMin - 0.05) < 1e-9)
    }

    // MARK: - Single-frame spike, 80ms floor

    @Test("a single-frame spike (1ms leg) is rejected by the 80ms floor even with ample amplitude")
    func singleFrameSpikeIsRejectedByPhaseFloor() throws {
        // Descent is a 1ms spike; ascent is a normal 100ms leg. Amplitude
        // on both legs comfortably clears A_min, isolating the failure to
        // the phase-duration floor alone.
        let c = Self.candidate(startT: 0.0, startX: 0.30, valleyT: 0.001, valleyX: 0.0, endT: 0.101, endX: 0.30)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.101, confidence: 0.9),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.101)
        )

        guard case .rejected(let rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(rejection.reasons.count == 1)
        guard case .phaseDurationTooShort(let duration, let descent, let ascent, let required) = try #require(rejection.reasons.first)
        else {
            Issue.record("expected .phaseDurationTooShort, got \(rejection.reasons)")
            return
        }
        #expect(abs(duration - 0.001) < 1e-9)
        #expect(abs(descent - 0.001) < 1e-9)
        #expect(abs(ascent - 0.100) < 1e-9)
        #expect(abs(required - 0.080) < 1e-9)
    }

    // MARK: - Low confidence

    @Test("a low-confidence cycle is rejected on confidence")
    func lowConfidenceCycleIsRejected() throws {
        let c = Self.candidate(startT: 0.0, startX: 0.30, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: 0.30)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.1),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.20)
        )

        guard case .rejected(let rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(rejection.reasons.count == 1)
        guard case .confidenceTooLow(let mean, let required) = try #require(rejection.reasons.first) else {
            Issue.record("expected .confidenceTooLow, got \(rejection.reasons)")
            return
        }
        #expect(abs(mean - 0.1) < 1e-9)
        #expect(abs(required - 0.5) < 1e-9)
    }

    // MARK: - Posture: throughout, not endpoints

    @Test("a cycle where posture dipped only in the middle is rejected")
    func postureDippingOnlyInMiddleIsRejected() throws {
        let c = Self.candidate(startT: 0.0, startX: 0.30, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: 0.30)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.9),
            postureHistory: Self.postureDippedOnlyInMiddle(from: 0.0, to: 0.20)
        )

        guard case .rejected(let rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(rejection.reasons.count == 1)
        guard case .postureNotHeldThroughout(let dippedAt, let reason) = try #require(rejection.reasons.first) else {
            Issue.record("expected .postureNotHeldThroughout, got \(rejection.reasons)")
            return
        }
        #expect(abs(dippedAt - 0.10) < 1e-9)
        #expect(reason == .noPlateTracked)
    }

    @Test("a cycle where posture held open throughout is accepted")
    func postureHeldThroughoutIsAccepted() throws {
        let c = Self.candidate(startT: 0.0, startX: 0.30, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: 0.30)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.9),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.20)
        )

        #expect(outcome.isAccepted)
    }

    // MARK: - Scale/threshold unit mismatch is refused

    @Test("a metres threshold against a torsoRelative signal is refused at construction, not silently applied")
    func metresThresholdAgainstTorsoRelativeScaleIsRefused() {
        #expect(throws: AmplitudeGate.ConfigurationError.self) {
            _ = try AmplitudeGate.Configuration(
                threshold: .metres(0.05), scale: .torsoRelative, minimumMeanConfidence: 0.5)
        }
    }

    @Test("a torso-length-fraction threshold against a metrically-trustworthy scale is refused")
    func torsoFractionThresholdAgainstPlateDiameterScaleIsRefused() {
        #expect(throws: AmplitudeGate.ConfigurationError.self) {
            _ = try AmplitudeGate.Configuration(
                threshold: .torsoLengthFraction(0.1), scale: .plateDiameter(mm: 450), minimumMeanConfidence: 0.5)
        }
    }

    @Test("a matching threshold/scale pairing constructs cleanly, for both units")
    func matchingThresholdScalePairingsConstruct() throws {
        _ = try AmplitudeGate.Configuration(threshold: .metres(0.05), scale: .plateDiameter(mm: 450), minimumMeanConfidence: 0.5)
        _ = try AmplitudeGate.Configuration(threshold: .metres(0.05), scale: .lidarBodyHeight(m: 1.8), minimumMeanConfidence: 0.5)
        _ = try AmplitudeGate.Configuration(
            threshold: .torsoLengthFraction(0.1), scale: .torsoRelative, minimumMeanConfidence: 0.5)
        _ = try AmplitudeGate.Configuration(
            threshold: .torsoLengthFraction(0.1), scale: .referenceHeight, minimumMeanConfidence: 0.5)
    }

    // MARK: - Multiple simultaneous failures, all reported

    @Test("a candidate failing amplitude, phase duration, confidence, and posture reports all four")
    func multipleSimultaneousFailuresAreAllReported() throws {
        // Tiny amplitude (below A_min), a 1ms spike leg (below the floor),
        // low confidence, and a posture dip mid-cycle — every check fails
        // independently.
        let c = Self.candidate(startT: 0.0, startX: 0.01, valleyT: 0.001, valleyX: 0.0, endT: 0.101, endX: 0.01)
        let configuration = try Self.makeConfiguration(threshold: .metres(0.05), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.101, confidence: 0.1),
            postureHistory: Self.postureDippedOnlyInMiddle(from: 0.0, to: 0.101)
        )

        guard case .rejected(let rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(rejection.reasons.count == 4)

        var sawAmplitude = false, sawPhase = false, sawConfidence = false, sawPosture = false
        for reason in rejection.reasons {
            switch reason {
            case .amplitudeTooSmall: sawAmplitude = true
            case .phaseDurationTooShort: sawPhase = true
            case .confidenceTooLow: sawConfidence = true
            case .postureNotHeldThroughout: sawPosture = true
            default: break
            }
        }
        #expect(sawAmplitude)
        #expect(sawPhase)
        #expect(sawConfidence)
        #expect(sawPosture)
    }

    // MARK: - Boundary: amplitude exactly at A_min

    @Test("amplitude exactly at A_min is accepted (inclusive boundary)")
    func amplitudeExactlyAtAMinIsAccepted() throws {
        let aMin = 0.05
        let c = Self.candidate(startT: 0.0, startX: aMin, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: aMin)
        let configuration = try Self.makeConfiguration(threshold: .metres(aMin), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.9),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.20)
        )

        #expect(outcome.isAccepted)
    }

    @Test("amplitude just below A_min is rejected")
    func amplitudeJustBelowAMinIsRejected() throws {
        let aMin = 0.05
        let justBelow = aMin - 0.0001
        let c = Self.candidate(startT: 0.0, startX: justBelow, valleyT: 0.10, valleyX: 0.0, endT: 0.20, endX: justBelow)
        let configuration = try Self.makeConfiguration(threshold: .metres(aMin), minimumMeanConfidence: 0.5)
        let gate = AmplitudeGate(configuration: configuration)

        let outcome = gate.evaluate(
            candidate: c,
            signalSamples: Self.confidenceSamples(from: 0.0, to: 0.20, confidence: 0.9),
            postureHistory: Self.postureOpenThroughout(from: 0.0, to: 0.20)
        )

        guard case .rejected(let rejection) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(rejection.reasons.contains { if case .amplitudeTooSmall = $0 { true } else { false } })
    }
}
