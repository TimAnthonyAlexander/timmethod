import Foundation
import Testing

@testable import TimMethodCore

/// All verification here is synthetic — hand-constructed amplitude
/// sequences, not real footage (matching `ZeroCrossCounterTests` /
/// `PostureGateTests` precedent, and this task's own instruction: "you can
/// construct candidate amplitudes directly").
///
/// **The real to-failure fixture is still owed.** SPEC §7.3 / W3-04's
/// Done-when calls for "a to-failure fixture where ROM visibly collapses
/// counts full reps and partials separately, matching hand annotation" —
/// that requires real footage of a lifter training to failure, which
/// depends on W1-06 (not done yet) and is W3-06's task, not this one.
/// `testToFailureRatchetHoldsWhileNaiveWouldNotHave` below simulates a
/// steadily-decaying ROM curve numerically to exercise the ratchet's logic
/// end to end, but a synthetic decay curve is not a substitute for hand
/// annotation against a real set. Treat this suite as validating the rule;
/// only the real clip validates the rule against reality.
@Suite("RangeCalibration")
struct RangeCalibrationTests {

    // MARK: - The ratchet: expansion only, and the failure it prevents

    @Test("a set whose amplitudes decay steadily keeps the original A_min, and shrinking reps land in the partial band rather than counting as full reps")
    func testRatchetHoldsAgainstDecay() {
        var set = SetCalibration(configuration: .init(seedFloor: 0.05))

        // First three reps establish the range at 0.30 (the max of the
        // three).
        let r1 = set.observe(amplitude: 0.30)
        let r2 = set.observe(amplitude: 0.29)
        let r3 = set.observe(amplitude: 0.28)
        #expect(r1.band == .full && r1.isEstablishing)
        #expect(r2.band == .full && r2.isEstablishing)
        #expect(r3.band == .full && r3.isEstablishing)
        #expect(set.establishedAmplitude == 0.30)
        #expect(set.fullRepCount == 3)

        let fullThreshold = 0.30 * 0.8   // 0.24
        let partialThreshold = 0.30 * 0.5 // 0.15

        // Fatigue sets in: amplitude decays steadily below A_min but above
        // the partial floor. The ratchet must NOT follow it down.
        let decaying: [Double] = [0.23, 0.20, 0.18, 0.16]
        for amplitude in decaying {
            #expect(amplitude < fullThreshold)
            #expect(amplitude >= partialThreshold)
            let observation = set.observe(amplitude: amplitude)
            #expect(observation.band == .partial)
            // The established range never moves for a rep this size.
            #expect(observation.establishedAmplitude == 0.30)
        }

        #expect(set.establishedAmplitude == 0.30, "A_min must not erode as ROM shrinks within the set")
        #expect(set.fullRepCount == 3, "no decaying rep should have counted toward the working count")
        #expect(set.partialRepCount == decaying.count)

        // Deep enough fatigue: below the partial floor entirely.
        let collapsed = set.observe(amplitude: 0.10)
        #expect(collapsed.band == .notARep)
        #expect(set.establishedAmplitude == 0.30)
    }

    @Test("the failure this task exists to prevent: a naive follow-the-extremes A_min would have kept counting the decaying reps as full, while the ratchet built here demotes them to partial")
    func testNaiveFollowExtremesWouldHaveCountedTheDecay() {
        // A naive rule that re-derives A_min from the *most recent* rep
        // each time (`A_min[n] = 0.8 * amplitude[n-1]`) — exactly the
        // "rolling auto-calibration... tracks observed extremes" rule SPEC
        // §7.3 rejects. This function exists only in this test file: it is
        // the bug, not the fix, and must never migrate into production
        // code.
        func naiveAMin(previousAmplitude: Double) -> Double {
            0.8 * previousAmplitude
        }

        var set = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = set.observe(amplitude: 0.30)
        _ = set.observe(amplitude: 0.30)
        _ = set.observe(amplitude: 0.30)
        #expect(set.establishedAmplitude == 0.30)

        // Each rep decays less than 20% from the one immediately before
        // it — gentle enough that a naive, most-recent-rep-relative floor
        // never catches up to the decay.
        var naivePrevious = 0.30
        let decaying: [Double] = [0.25, 0.21, 0.18, 0.16]
        var naiveFullCount = 0
        var divergences = 0
        for amplitude in decaying {
            let naiveWouldAccept = amplitude >= naiveAMin(previousAmplitude: naivePrevious)
            if naiveWouldAccept {
                naiveFullCount += 1
            }
            let realBand = set.observe(amplitude: amplitude).band
            if naiveWouldAccept && realBand != .full {
                divergences += 1
            }
            naivePrevious = amplitude
        }

        // The naive rule keeps re-basing its own floor on whatever it just
        // saw, so it would have counted every one of these fatigue-shrunk
        // reps as full — it never once rejects.
        #expect(naiveFullCount == decaying.count)

        // The ratchet built in this task holds A_min fixed at 80% of the
        // range established from the first three reps, and correctly
        // demotes the later, shrinking reps to partial instead — this
        // divergence (naive says full, ratchet says partial) is exactly
        // the bug SPEC §7.3 documents and this task exists to fix.
        #expect(divergences == 3)
        #expect(set.fullRepCount == 4) // the 3 establishing reps, plus 0.25 which still clears the real 80% floor
        #expect(set.partialRepCount == 3) // 0.21, 0.18, 0.16 — all "full" under the naive rule
    }

    @Test("one unusually deep warm-up rep raises the baseline within the set")
    func testDeepRepRatchetsUpWithinSet() {
        var set = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = set.observe(amplitude: 0.30)
        _ = set.observe(amplitude: 0.29)
        _ = set.observe(amplitude: 0.30)
        #expect(set.establishedAmplitude == 0.30)

        // An unusually deep rep after establishment raises the baseline.
        let deep = set.observe(amplitude: 0.45)
        #expect(deep.band == .full)
        #expect(set.establishedAmplitude == 0.45)

        // Subsequent bands are now judged against the raised baseline.
        let next = set.observe(amplitude: 0.30) // 0.30 / 0.45 ≈ 0.667 -> partial
        #expect(next.band == .partial)
    }

    // MARK: - Band edges

    @Test("exactly 80% of established range is full, exactly 50% is partial, just under 50% is not a rep")
    func testBandEdges() {
        var set = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = set.observe(amplitude: 0.40)
        _ = set.observe(amplitude: 0.40)
        _ = set.observe(amplitude: 0.40)
        #expect(set.establishedAmplitude == 0.40)

        let fullEdge = 0.40 * SetCalibration.Configuration.defaultFullFraction
        let partialEdge = 0.40 * SetCalibration.Configuration.defaultPartialFraction

        // Exactly on the 80% edge: full (AmplitudeGate's own `<` rejection
        // convention means `>=` accepts — this file matches it).
        var probe = set
        #expect(probe.observe(amplitude: fullEdge).band == .full)

        // Just under 80%: partial.
        probe = set
        #expect(probe.observe(amplitude: fullEdge.nextDown).band == .partial)

        // Exactly on the 50% edge: partial (inclusive lower bound of the
        // partial band).
        probe = set
        #expect(probe.observe(amplitude: partialEdge).band == .partial)

        // Just under 50%: not a rep.
        probe = set
        #expect(probe.observe(amplitude: partialEdge.nextDown).band == .notARep)
    }

    // MARK: - The bootstrap problem

    @Test("the bootstrap attack: a garbage twitch during setup does not establish a garbage baseline that then admits every twitch after it")
    func testBootstrapAttackRejectsGarbageSeed() {
        // Cold start: no cross-session history yet, so the floor is
        // whatever AmplitudeGate's own static threshold already is today
        // (this file's doc: bootstrap is never more permissive than the
        // shipped, unratcheted gate).
        let coldStartFloor = RangeCalibration.seedFloor(crossSessionMedian: nil, coldStartFloor: 0.05)
        #expect(coldStartFloor == 0.05)

        var set = SetCalibration(configuration: .init(seedFloor: coldStartFloor))

        // A twitch during setup: tiny, far below any real rep.
        let twitch = set.observe(amplitude: 0.02)
        #expect(twitch.band == .notARep)
        #expect(twitch.establishedAmplitude == nil)

        // If the twitch HAD been admitted as accepted-rep #1, three more
        // twitch-scale candidates would suffice to "establish" a garbage
        // ~0.02 baseline, at which point genuinely tiny motion afterward
        // would clear an 80%-of-0.02 threshold trivially. Assert that does
        // not happen: the twitch never counted, so establishment still
        // requires three *real* reps.
        let stillBootstrapping = set.observe(amplitude: 0.01)
        #expect(stillBootstrapping.band == .notARep)
        #expect(set.establishedAmplitude == nil)
        #expect(set.fullRepCount == 0)

        // Three real reps now establish the range correctly, uncorrupted by
        // the two twitches that came before them.
        _ = set.observe(amplitude: 0.30)
        _ = set.observe(amplitude: 0.29)
        let third = set.observe(amplitude: 0.31)
        #expect(third.isEstablishing)
        #expect(set.establishedAmplitude == 0.31)
        #expect(set.fullRepCount == 3)

        // And a twitch-scale amplitude after establishment is correctly
        // rejected as not-a-rep against the real, uncorrupted baseline —
        // the failure mode this test's title describes never materializes.
        let twitchAfter = set.observe(amplitude: 0.02)
        #expect(twitchAfter.band == .notARep)
    }

    @Test("the bootstrap floor from cross-session history is 50% of the median, not the raw median")
    func testBootstrapFloorFromHistory() {
        let floor = RangeCalibration.seedFloor(crossSessionMedian: 0.30, coldStartFloor: 0.05)
        #expect(floor == 0.15)
    }

    // MARK: - Cross-session baseline: median, not mean or EMA

    @Test("one bad session does not erode the cross-session median")
    func testBadSessionDoesNotErodeMedian() {
        var baseline = CrossSessionBaseline()
        for _ in 0..<5 {
            baseline.recordSessionMaximum(0.30)
        }
        #expect(baseline.median == 0.30)

        // One unusually bad session (e.g. an off day, or fatigue in a
        // session with only one, badly-shrunk set).
        baseline.recordSessionMaximum(0.10)

        // 6 values sorted: [0.10, 0.30, 0.30, 0.30, 0.30, 0.30] — median is
        // the average of the middle two, both 0.30.
        #expect(baseline.median == 0.30)
    }

    @Test("one deep warm-up rep raises the baseline within its own set/session but does not permanently raise the cross-session standard")
    func testDeepWarmupDoesNotPermanentlyRaiseCrossSessionStandard() {
        var baseline = CrossSessionBaseline()
        for _ in 0..<5 {
            baseline.recordSessionMaximum(0.30)
        }
        #expect(baseline.median == 0.30)

        // A session where a deep warm-up rep ratcheted one set's
        // `establishedAmplitude` way up (see testDeepRepRatchetsUpWithinSet
        // for that within-set mechanism) contributes its inflated maximum
        // as a single session entry.
        baseline.recordSessionMaximum(0.55)

        // 6 values sorted: [0.30, 0.30, 0.30, 0.30, 0.30, 0.55] — median
        // stays at the lifter's real standard, nowhere near 0.55.
        #expect(baseline.median == 0.30)
    }

    @Test("median, not mean: a mean would have moved noticeably; the median does not")
    func testMedianNotMean() {
        var baseline = CrossSessionBaseline()
        for _ in 0..<5 {
            baseline.recordSessionMaximum(0.30)
        }
        baseline.recordSessionMaximum(0.55)

        let mean = baseline.sessionMaxima.reduce(0, +) / Double(baseline.sessionMaxima.count)
        #expect(mean > 0.34) // mean is visibly dragged toward the outlier
        #expect(baseline.median == 0.30) // median is not
    }

    @Test("median with no sessions recorded is nil")
    func testMedianNilWhenEmpty() {
        let baseline = CrossSessionBaseline()
        #expect(baseline.median == nil)
    }

    // MARK: - Sets that end early must not corrupt the cross-session baseline

    @Test("fewer than three reps in a set never establishes a range, and contributes nothing to the cross-session baseline")
    func testEarlyEndedSetDoesNotEstablish() {
        var set = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = set.observe(amplitude: 0.30)
        _ = set.observe(amplitude: 0.29)
        // Set ends here — only 2 accepted reps, one short of establishment.
        #expect(set.establishedAmplitude == nil)

        let contribution = RangeCalibration.sessionMaximum(setEstablishedAmplitudes: [set.establishedAmplitude])
        #expect(contribution == nil)
    }

    @Test("a session mixing an early-ended set and a properly-established set only reports the established one's maximum")
    func testSessionMaximumIgnoresEarlyEndedSets() {
        var earlyEnded = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = earlyEnded.observe(amplitude: 0.20)
        #expect(earlyEnded.establishedAmplitude == nil)

        var established = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = established.observe(amplitude: 0.32)
        _ = established.observe(amplitude: 0.31)
        _ = established.observe(amplitude: 0.33)
        #expect(established.establishedAmplitude == 0.33)

        let sessionMax = RangeCalibration.sessionMaximum(
            setEstablishedAmplitudes: [earlyEnded.establishedAmplitude, established.establishedAmplitude])
        #expect(sessionMax == 0.33)
    }

    @Test("a session where every set ends early contributes nothing at all")
    func testSessionMaximumNilWhenNoSetEstablishes() {
        var a = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = a.observe(amplitude: 0.20)
        var b = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = b.observe(amplitude: 0.22)
        _ = b.observe(amplitude: 0.21)

        let sessionMax = RangeCalibration.sessionMaximum(
            setEstablishedAmplitudes: [a.establishedAmplitude, b.establishedAmplitude])
        #expect(sessionMax == nil)
    }

    // MARK: - Set-scoped vs. cross-session separation

    @Test("SetCalibration state resets per set: a fresh instance carries none of another set's ratcheted range")
    func testSetScopedStateResetsPerSet() {
        var first = SetCalibration(configuration: .init(seedFloor: 0.05))
        _ = first.observe(amplitude: 0.50)
        _ = first.observe(amplitude: 0.50)
        _ = first.observe(amplitude: 0.50)
        #expect(first.establishedAmplitude == 0.50)

        // A second set — even for the same exercise, same session — starts
        // from a completely independent, blank `SetCalibration`. It is not
        // seeded from `first`'s establishedAmplitude at all; only the
        // caller-supplied `seedFloor` (itself derived from cross-session
        // history, not from any single prior set) carries forward.
        var second = SetCalibration(configuration: .init(seedFloor: 0.05))
        #expect(second.establishedAmplitude == nil)
        let r = second.observe(amplitude: 0.10)
        #expect(r.isEstablishing) // still bootstrapping, unaffected by `first`
    }

    // MARK: - Simulated to-failure curve (synthetic; the real fixture is still owed — see suite doc)

    @Test("synthetic to-failure simulation: full and partial reps are tallied separately as ROM collapses toward the end of a set")
    func testToFailureRatchetHoldsWhileNaiveWouldNotHave() {
        // A stylised to-failure set: 3 strong reps establish the range,
        // several more hold steady, then ROM collapses steadily toward
        // failure. This is a synthetic stand-in — see this suite's
        // top-level doc for why the real to-failure fixture (W3-06,
        // depends on W1-06) is still required and not replaced by this.
        let amplitudes: [Double] = [
            0.40, 0.40, 0.40, // establish
            0.39, 0.41, 0.38, // holds near the top of the set
            0.30, 0.28, 0.24, // fringe of the full band as fatigue starts (0.8*0.41=0.328 if ratcheted up, else 0.32)
            0.19, 0.15, 0.12, // partial band
            0.08, // collapsed: not a rep
        ]

        var set = SetCalibration(configuration: .init(seedFloor: 0.05))
        var bands: [SetCalibration.Band] = []
        for amplitude in amplitudes {
            bands.append(set.observe(amplitude: amplitude).band)
        }

        // Establishment ratchets up to 0.41 (the deepest of the early
        // reps), so A_min = 0.328, partial floor = 0.205.
        #expect(set.establishedAmplitude == 0.41)
        #expect(bands[0...5] == [.full, .full, .full, .full, .full, .full])
        // 0.30, 0.28, 0.24 are all below 0.328 -> partial.
        #expect(bands[6...8] == [.partial, .partial, .partial])
        // 0.19, 0.15, 0.12 are all below 0.205 -> not a rep (0.19 < 0.205).
        #expect(bands[9...11] == [.notARep, .notARep, .notARep])
        // 0.08 -> not a rep.
        #expect(bands[12] == .notARep)

        #expect(set.fullRepCount == 6)
        #expect(set.partialRepCount == 3)
    }
}
