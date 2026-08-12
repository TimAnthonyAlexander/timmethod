import Foundation

/// What any rep counter — real or stub — hands back for one fully-replayed
/// clip (SPEC §7.2, §15).
///
/// Every field that a conformer cannot honestly produce must come back as
/// `nil`/empty rather than a fabricated `0`. `timmethod-eval` (SPEC §15)
/// depends on that: it is what lets the harness tell "the counter measured
/// zero partials" apart from "this counter doesn't classify partials at
/// all," instead of silently treating both as the same zero.
public struct RepCountResult: Sendable, Equatable {
    /// Total reps detected across the clip. Never negative.
    public var repCount: Int

    /// Timestamp of each detected rep's completion, oldest first, same
    /// clock as `RepSignal.Sample.t`. Empty when the conformer does not
    /// report per-rep timing (never a placeholder guess) — the harness only
    /// does timestamp-level false-positive/false-negative matching
    /// (`ClipEvaluator`) when this is non-empty.
    public var repTimestamps: [TimeInterval]

    /// Of `repCount`, how many the conformer itself classified as partial
    /// (SPEC §12 `WorkSet.partialReps`). `nil` when the conformer does not
    /// attempt partial classification — the harness must not fabricate a
    /// `0` for a measurement that was never taken.
    public var partialCount: Int?

    public init(repCount: Int, repTimestamps: [TimeInterval] = [], partialCount: Int? = nil) {
        precondition(repCount >= 0, "RepCountResult.repCount must not be negative")
        self.repCount = repCount
        self.repTimestamps = repTimestamps
        self.partialCount = partialCount
    }
}

/// The counter seam (SPEC §7.2). `timmethod-eval` depends only on this
/// protocol, never on a concrete counter, so the real Wave 3 counter
/// (zero-crossing + amplitude gate + ratcheting calibration + posture gate)
/// drops in behind the harness without the harness changing at all.
///
/// Deliberately narrow: one method, one input, one output. This is *not* an
/// attempt to anticipate Wave 3's design — the real counter will very likely
/// need more than a single finished `RepSignal` (streaming input, a
/// calibration state that persists across reps, posture-gate context). This
/// protocol only has to be enough for the harness to run today; Wave 3 is
/// free to wrap or replace it.
public protocol RepCounting: Sendable {
    /// Counts reps across one complete clip's signal, oldest sample first.
    /// Synchronous and pure with respect to `signal` — a conformer that
    /// needs async setup (loading a model, say) does that in its own
    /// initializer, not here.
    func count(signal: RepSignal) -> RepCountResult
}

/// The one stub conformer W1-05 ships (SPEC §15's "Done when: runs end to
/// end against a stub counter"). Wave 3 replaces this; nothing else in the
/// harness changes when it does.
///
/// This is a genuinely minimal amplitude-gated swing counter — it walks
/// `signal.samples.x`, tracks the running peak and trough since the last
/// direction reversal, and counts one rep each time the signal swings up by
/// at least `minAmplitude` from a trough and back down by at least
/// `minAmplitude` from the following peak. It is *not* SPEC §7.2's counter:
/// no calibration ratchet (§7.3), no posture gate, no confidence weighting,
/// and `minAmplitude` is an arbitrary untuned constant, not a fitted
/// threshold. It exists so the eval harness's scoring, gate, and trace-dump
/// machinery has a real (if unimpressive) prediction to run against before
/// Wave 3 exists — including the honest case: fed the flat, untracked
/// placeholder signal `timmethod-eval` builds until Track A (Wave 2) lands,
/// this counts zero reps for every clip, which is the correct answer for a
/// signal that never moved.
public struct StubRepCounter: RepCounting, Sendable {
    /// Minimum swing, in `RepSignal.Sample.x`'s units, required to register
    /// as a rep half-cycle. Arbitrary placeholder — Wave 3 fits a real
    /// value against calibration data (SPEC §7.3); this only needs to be
    /// small enough not to swallow whatever a future real signal looks
    /// like, and large enough not to count sample-to-sample jitter.
    public let minAmplitude: Double

    public init(minAmplitude: Double = 0.02) {
        self.minAmplitude = minAmplitude
    }

    public func count(signal: RepSignal) -> RepCountResult {
        guard signal.samples.count > 0 else {
            return RepCountResult(repCount: 0)
        }

        var repCount = 0
        var repTimestamps: [TimeInterval] = []

        var troughX = signal.samples[0].x
        var peakX = signal.samples[0].x
        var risingFromTrough = true // waiting to confirm a rise of >= minAmplitude

        for index in 1..<signal.samples.count {
            let sample = signal.samples[index]

            if risingFromTrough {
                if sample.x < troughX {
                    troughX = sample.x
                } else if sample.x - troughX >= minAmplitude {
                    peakX = sample.x
                    risingFromTrough = false
                }
            } else {
                if sample.x > peakX {
                    peakX = sample.x
                } else if peakX - sample.x >= minAmplitude {
                    // Completed one full up/down swing: one rep.
                    repCount += 1
                    repTimestamps.append(sample.t)
                    troughX = sample.x
                    risingFromTrough = true
                }
            }
        }

        return RepCountResult(repCount: repCount, repTimestamps: repTimestamps, partialCount: nil)
    }
}
