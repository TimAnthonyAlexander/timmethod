import Foundation

/// The signal both tracks reduce to (SPEC §6).
///
/// Track A (plate detection) produces this from plate-centroid displacement
/// along the fitted motion axis. Track B (pose) produces it by projecting
/// smoothed landmark positions onto the first principal component of the
/// trajectory over a sliding window. Downstream of this type — gating
/// (§7.1), the counter (§7.2), calibration (§7.3), velocity (§8.1) — there is
/// exactly one implementation, because both tracks hand it the same shape.
/// This type is the whole reason for that: keep it narrow.
public struct RepSignal: Sendable {
    /// One scalar sample of the tracked motion axis.
    ///
    /// `x` is in **metres**, along the lift's working axis, and is
    /// **positive moving away from the ground** — e.g. the concentric /
    /// lockout direction for a squat, bench press, or pull-up. This sign
    /// convention is a fact every downstream consumer (counter, velocity,
    /// ROM) assumes without re-deriving it. Get it backwards at the source
    /// (Track A or Track B) and every rep looks inverted three layers away
    /// from here, in code that has no way to tell.
    ///
    /// Whether `x` can be trusted as an absolute distance — as opposed to
    /// only a relative one — depends on `RepSignal.scale`, not on anything
    /// in `Sample` itself.
    public struct Sample: Sendable, Equatable {
        /// Capture timestamp, seconds, same clock as the frame source.
        public let t: TimeInterval
        /// Position along the working axis, metres, signed per the type doc.
        public let x: Double
        /// Tracking confidence for this sample, `0...1`.
        public let confidence: Double

        public init(t: TimeInterval, x: Double, confidence: Double) {
            self.t = t
            self.x = x
            self.confidence = confidence
        }
    }

    /// How the metre scale in `Sample.x` was established (SPEC §6, §12).
    ///
    /// This is not cosmetic: it determines whether an absolute quantity
    /// derived from `x` — a distance in metres, a velocity in m/s — is a
    /// measurement or a guess, and the UI has to be able to tell those apart
    /// instead of presenting every case with equal confidence.
    public enum ScaleSource: Sendable, Equatable {
        /// Best case: a known physical object (a barbell plate) of known
        /// diameter, measured directly in frame. Accurate to roughly ±1%.
        case plateDiameter(mm: Double)

        /// Good: a measured body dimension from a LiDAR-backed capture
        /// session (Track B on LiDAR-equipped hardware). A real,
        /// per-user measurement, not a population average.
        case lidarBodyHeight(m: Double)

        /// Poor: no LiDAR. Apple's pose API silently substitutes a fixed
        /// 1.8 m assumed body height when the capture session is not
        /// LiDAR-backed, so every metre downstream carries an error
        /// proportional to `(true height − 1.8) / 1.8` for that specific
        /// user — a 1.65 m lifter sees roughly +9% on every ROM and
        /// velocity number, a 1.95 m lifter roughly −8%. This case exists
        /// so the UI can flag that substitution instead of presenting the
        /// number as if it had been measured.
        case referenceHeight

        /// No absolute scale at all. `x` is meaningful only as a ratio
        /// against other samples of the *same* signal (e.g. percent of
        /// established ROM). There is no metres-per-unit conversion.
        /// Absolute quantities derived from this — metres, m/s — must come
        /// out as `nil`, never as a number computed by assuming a scale
        /// that isn't there. Refuse rather than guess.
        case torsoRelative

        /// Whether an absolute metric quantity (metres, m/s) derived from
        /// this scale is a real-world measurement fit to show the user, as
        /// opposed to a relative-only quantity that must not be presented
        /// as absolute.
        ///
        /// `false` for `.referenceHeight` — it's a population average
        /// standing in for a personal measurement, wrong by construction
        /// for almost everyone — and for `.torsoRelative` — there is no
        /// metre scale to be right or wrong about. Code computing
        /// `romMetres` / `meanConcentricVelocity` (SPEC §12) should check
        /// this rather than silently emit a number that merely type-checks.
        public var isMetricallyTrustworthy: Bool {
            switch self {
            case .plateDiameter, .lidarBodyHeight:
                true
            case .referenceHeight, .torsoRelative:
                false
            }
        }
    }

    /// 180 s at 60 Hz.
    ///
    /// 180 s is the longest plausible single working set — sets end well
    /// before this via a velocity-loss or rep-target stop condition (SPEC
    /// §7.3, §12 `StopReason`), so this is headroom, not an expected size.
    /// 60 Hz is the frame-rate ceiling shared by both tracks (Vision pose
    /// and plate detection both run at camera rate, capped at 60 fps on
    /// supported devices, SPEC §16). 180 * 60 = 10,800 samples of three
    /// `Double`s each — a few hundred KB however the backing storage pads
    /// it, so there's no reason to size it tighter.
    public static let defaultCapacity = 180 * 60

    /// Default resolution for `trace(targetCount:)`. 128 points is enough
    /// visual resolution to show one rep's concentric+eccentric shape on a
    /// phone-width sparkline, and small enough that persisting it as
    /// `Rep.signalTrace` (SPEC §12) per rep is cheap.
    public static let defaultTraceCount = 128

    /// Samples of the tracked motion axis, oldest first, capacity-bounded.
    ///
    /// `var`, not `let`: appending is the entire point of this type, and a
    /// `let` ring buffer can never grow. (The SPEC §6 sketch writes `let`;
    /// that's a sketch, not a constraint — a signal you can't append to
    /// isn't a signal.)
    public var samples: RingBuffer<Sample>

    /// How the metre scale in every `samples[i].x` was established.
    public let scale: ScaleSource

    /// Creates an empty signal with the given scale and capacity.
    ///
    /// `capacity` defaults to `RepSignal.defaultCapacity` (180 s at 60 Hz);
    /// callers running at a different frame rate or fixture duration can
    /// override it.
    public init(scale: ScaleSource, capacity: Int = RepSignal.defaultCapacity) {
        self.scale = scale
        self.samples = RingBuffer(capacity: capacity)
    }

    /// Appends one sample. O(1); see `RingBuffer.append`.
    public mutating func append(t: TimeInterval, x: Double, confidence: Double) {
        samples.append(Sample(t: t, x: x, confidence: confidence))
    }

    /// A downsampled export of `x`, oldest to newest, resampled to exactly
    /// `targetCount` points. This is what feeds `Rep.signalTrace` (SPEC
    /// §12) and the eval harness report — the record that makes a bad rep
    /// count debuggable after the fact instead of unreproducible.
    ///
    /// **Method: linear resampling at `targetCount` evenly-spaced query
    /// positions across the buffer's index range**, interpolating between
    /// the two nearest real samples at each query position. This is chosen
    /// over nearest-neighbour decimation because it doesn't silently jump
    /// between un-interpolated values, and over bucketed min/max decimation
    /// because it keeps output samples evenly spaced in time, which matters
    /// for a trace a human is going to look at as a waveform.
    ///
    /// **What it costs:** resampling is by sample *index*, not by
    /// timestamp — camera frame delivery is time-uniform to within jitter
    /// noise, so for this signal that's equivalent to time-based resampling
    /// and considerably simpler. More importantly, linear interpolation
    /// can attenuate or miss a feature narrower than the query spacing
    /// (`buffer duration / targetCount`). A rep's concentric/eccentric
    /// swing is well under 2 Hz, so at the default 128-point target over a
    /// signal of any realistic single-rep or single-set duration the query
    /// rate is far above Nyquist for that content and shape is preserved;
    /// a single-frame spike sitting between two query positions, though,
    /// would be smoothed rather than captured. That's an acceptable
    /// trade-off for a debugging trace of rep-scale motion, not for
    /// frame-scale glitch detection.
    public func trace(targetCount: Int = RepSignal.defaultTraceCount) -> [Float] {
        guard targetCount > 0 else { return [] }
        let n = samples.count
        guard n > 0 else { return [] }
        guard n > 1 else {
            return Array(repeating: Float(samples[0].x), count: targetCount)
        }

        let lastIndex = Double(n - 1)
        let lastSlot = Double(Swift.max(targetCount - 1, 1))
        var result: [Float] = []
        result.reserveCapacity(targetCount)

        for slot in 0..<targetCount {
            let position = targetCount == 1 ? 0 : (Double(slot) / lastSlot) * lastIndex
            let lowerIndex = Int(position.rounded(.down))
            let upperIndex = Swift.min(lowerIndex + 1, n - 1)
            let fraction = position - Double(lowerIndex)
            let lowerX = samples[lowerIndex].x
            let upperX = samples[upperIndex].x
            result.append(Float(lowerX + (upperX - lowerX) * fraction))
        }
        return result
    }
}
