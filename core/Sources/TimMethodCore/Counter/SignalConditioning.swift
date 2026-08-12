import Foundation

/// Turns a raw `RepSignal` into the detrended-signal-plus-velocity pair the
/// counter (W3-02, a different task) reads (SPEC §4.1, §7.2; W3-01).
///
/// Everything the counter does keys off zero crossings of velocity. A
/// drifting baseline (the lifter shifting stance, the camera settling) or a
/// noisy derivative destroys that directly, upstream of any clever counting
/// logic — which is why this is its own file rather than folded into the
/// counter itself: get this wrong and no amount of amplitude-gate or
/// calibration cleverness downstream can recover the signal.
///
/// This file builds exactly the three primitives SPEC §7.2's diagram names,
/// plus the composition that chains them:
///
/// ```
/// signal → [ OneEuroFilter, off by default ]
///        → RollingMedianDetrend (rolling median, ~3s window)
///        → Derivative.centralDifference (real inter-sample dt)
/// ```
///
/// `SignalConditioningPipeline` is the composed entry point W3-02 is
/// expected to call. It does **not** do zero-crossing detection, amplitude
/// gating, phase tracking, or any rep-state logic — only signal
/// conditioning. That line is deliberate: this task is W3-01, the counter
/// itself is W3-02.
///
/// ## Why median, not mean, for detrending
///
/// A mean is dragged by the rep excursions themselves — exactly the signal
/// this is trying to keep. A rolling mean over a window that contains one
/// full concentric+eccentric swing is biased toward wherever in the swing
/// the window happens to sit; a rolling median is far more robust to that,
/// which is the entire reason `RollingMedianDetrend` computes a median
/// rather than an average of the window.
///
/// ## Why the window is causal, not centred
///
/// `MotionAxis` (`PlateTrack/MotionAxis.swift`, a different file, not
/// modified by this task) fits its PCA window over trailing history only —
/// the *pattern* this file follows, per this task's brief. The same
/// causality constraint applies here for the same reason: this signal is
/// read live, frame by frame, during a set, and a centred window would need
/// roughly half the window's duration (up to ~1.5s at the 3s default) of
/// *future* samples before it could emit anything, which is not available
/// yet when a frame just arrived. `RollingMedianDetrend.observe(t:x:)`
/// therefore computes the median of the trailing `windowSeconds` only, and
/// its causal lag on a real drift is small relative to the window as long
/// as the drift itself is slow relative to the window (the entire premise
/// of "slow drift" this type exists to remove) — see
/// `SignalConditioningTests` for the drift-removal-vs-rep-amplitude
/// regression coverage.
///
/// ## Why the window is time-based, not frame-counted
///
/// Same reasoning as `MotionAxis.windowDurationSeconds` (see that type's
/// doc, "Window: length and its extremes"): fixture clips and live capture
/// both vary between 30 and 60 fps (SPEC §16), and frames drop under
/// thermal load, so a frame-count window would silently cover a different
/// real-world duration depending on frame rate or drop pattern. Filtering
/// the backing buffer by `t - entry.t` each call, exactly like `MotionAxis`,
/// makes the window's real-world duration invariant to both.
///
/// ## Why the derivative uses each sample's own dt, never an assumed rate
///
/// `ReplayFrameSource` (`Capture/ReplayFrameSource.swift`, not modified by
/// this task) is deliberately careful to never synthesise a uniform clock
/// from an assumed frame rate — its own doc calls that "the single most
/// important correctness requirement" it has, because fixture clips are
/// pulled from several datasets at several different frame rates and a
/// fabricated 60 Hz clock would silently corrupt every velocity measurement
/// computed against a clip that wasn't actually shot at 60 Hz. The same bug,
/// one layer up: if this file assumed a frame period instead of reading
/// `samples[i].t - samples[i-1].t`, every velocity this file ever produced
/// would carry that same silent corruption, on every clip, on every device,
/// under thermal frame drops especially. `Derivative.centralDifference`
/// reads real timestamps and nothing else.
///
/// ## Why the central-difference weights are unequal-spacing-correct
///
/// The naive generalisation of central difference to irregular spacing —
/// `(x[i+1] - x[i-1]) / (t[i+1] - t[i-1])` — is only first-order accurate
/// when the two neighbouring gaps differ (its error grows with
/// `|h2 - h1|`), which is exactly the situation a genuinely irregular
/// capture produces. `Derivative.centralDifference` instead uses the
/// 3-point, unequally-spaced finite-difference weights derived from a
/// Taylor expansion around `t[i]` with gaps `h1 = t[i] - t[i-1]` and
/// `h2 = t[i+1] - t[i]`:
///
/// ```
/// v[i] = A·x[i-1] + B·x[i] + C·x[i+1]
/// A = -h2 / (h1·(h1+h2))
/// B = (h2 - h1) / (h1·h2)
/// C =  h1 / (h2·(h1+h2))
/// ```
///
/// which is second-order accurate (error `O(h²)`) regardless of the `h1/h2`
/// ratio, and collapses to the familiar `(x[i+1] - x[i-1]) / (2h)` when
/// `h1 = h2 = h`. `SignalConditioningTests` proves both the uniform case
/// (headline correctness, matches an analytic sine derivative) and a
/// genuinely irregular-spacing case (the regression guard this task's brief
/// specifically calls for).
///
/// ## Why the One Euro filter is a separate, off-by-default step
///
/// SPEC §4.1: MediaPipe already applies a One Euro filter internally in
/// stream mode (2D normalized at min_cutoff 0.05 / beta 80, world landmarks
/// at 0.1 / 40), so a second filter on top double-smooths and stacks lag.
/// Whether Apple Vision filters internally is undocumented — that is
/// exactly what `--jitter-report` (`timmethod-eval`, a CLI-side file, not
/// this one) exists to measure before anything gets turned on. And if
/// smoothing turns out to be needed at all, filtering the 1D `RepSignal`
/// here beats filtering 33 landmarks × 3 coordinates upstream: one filter,
/// one parameter pair, a third of the lag, and it's the only signal the
/// counter reads anyway (SPEC §4.1's own conclusion).
///
/// `OneEuroFilter` is therefore its own standalone type that nothing in
/// this file invokes unless a caller explicitly opts in via
/// `SignalConditioningPipeline.Configuration.smoothing`, which defaults to
/// `nil`. `nil` means *skip the filter step entirely*, not "run it with
/// neutral parameters" — `SignalConditioningTests` asserts the default path
/// is bit-for-bit identical to never having a filter in the picture at all,
/// which a "run with identity-ish parameters" implementation would not be
/// (a low-pass filter, even a gentle one, is not the identity function).
public enum SignalConditioning {}

// MARK: - Rolling-median detrend

/// Causal, time-windowed rolling-median detrend (SPEC §7.2's `detrend
/// (rolling median, 3s window)` pipeline stage; this task item 1).
///
/// See this file's top-level doc for why median (not mean), why causal (not
/// centred), and why time-based (not frame-counted).
public struct RollingMedianDetrend: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// How much trailing history the median is computed over. See
        /// `RollingMedianDetrend.defaultWindowSeconds`.
        public var windowSeconds: Double

        public init(windowSeconds: Double = RollingMedianDetrend.defaultWindowSeconds) {
            precondition(
                windowSeconds.isFinite && windowSeconds > 0,
                "RollingMedianDetrend.Configuration.windowSeconds must be finite and positive"
            )
            self.windowSeconds = windowSeconds
        }
    }

    /// 3.0 s. SPEC §7.2 names this window explicitly ("rolling median, 3s
    /// window") — long enough to comfortably outlast a single rep's
    /// concentric+eccentric swing (SPEC §7.2 treats a half-cycle as "order
    /// of a second or more"; `MotionAxis.defaultWindowDurationSeconds`
    /// makes the analogous argument at 6s for its own, different, PCA-fit
    /// window) so the median tracks the lifter's slowly-shifting baseline
    /// rather than the rep oscillation riding on top of it, while staying
    /// short enough that a real stance shift or camera settle is reflected
    /// within a few seconds rather than dragging for the rest of the set.
    public static let defaultWindowSeconds: Double = 3.0

    public let configuration: Configuration
    private var window: [(t: TimeInterval, x: Double)] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public static func == (lhs: RollingMedianDetrend, rhs: RollingMedianDetrend) -> Bool {
        lhs.configuration == rhs.configuration
            && lhs.window.count == rhs.window.count
            && zip(lhs.window, rhs.window).allSatisfy { $0.t == $1.t && $0.x == $1.x }
    }

    /// Advances by one sample, in capture order (like `MotionAxis.observe`,
    /// this is causal: a call only ever sees samples from calls before it).
    /// Returns `x` minus the median of `x` over the trailing
    /// `configuration.windowSeconds`, inclusive of this sample.
    public mutating func observe(t: TimeInterval, x: Double) -> Double {
        window.append((t: t, x: x))
        while let oldest = window.first, t - oldest.t > configuration.windowSeconds {
            window.removeFirst()
        }
        return x - Self.median(window.map(\.x))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Batch convenience over `observe(t:x:)`: detrends a whole
    /// `RepSignal.Sample` array in one call, preserving each sample's `t`
    /// and `confidence` and replacing only `x`. Built on the same streaming
    /// `observe(t:x:)` a live counter would call frame by frame, so batch
    /// and streaming use can never numerically disagree.
    public static func detrend(
        _ samples: [RepSignal.Sample],
        windowSeconds: Double = RollingMedianDetrend.defaultWindowSeconds
    ) -> [RepSignal.Sample] {
        var filter = RollingMedianDetrend(configuration: Configuration(windowSeconds: windowSeconds))
        return samples.map { sample in
            RepSignal.Sample(t: sample.t, x: filter.observe(t: sample.t, x: sample.x), confidence: sample.confidence)
        }
    }
}

// MARK: - Central-difference derivative

/// One velocity estimate, at a sample's own timestamp.
public struct VelocitySample: Sendable, Equatable {
    public let t: TimeInterval
    public let v: Double

    public init(t: TimeInterval, v: Double) {
        self.t = t
        self.v = v
    }
}

/// Central-difference derivative over real, possibly non-uniform,
/// inter-sample spacing (this task item 2). See this file's top-level doc,
/// "Why the derivative uses each sample's own dt" and "Why the
/// central-difference weights are unequal-spacing-correct", for the full
/// reasoning and the closed-form weights used below.
public enum Derivative {
    /// Returns one `VelocitySample` per **interior** sample of `samples`
    /// (indices `1..<samples.count - 1`): central difference needs both a
    /// predecessor and a successor, so the first and last samples have no
    /// central-difference estimate here. This never falls back to a
    /// one-sided (forward/backward) difference for those endpoints — mixing
    /// formulas within a single signal would make the resulting velocity
    /// trace's noise characteristics inconsistent sample to sample for no
    /// benefit; a live counter simply has no velocity for the newest sample
    /// until the next one arrives, which is a one-sample lag, not a
    /// correctness gap.
    ///
    /// A pair of adjacent samples with a non-positive or non-finite gap
    /// (out-of-order or duplicate timestamps) is skipped rather than
    /// producing a fabricated or infinite velocity — the same "a gap is a
    /// gap, never a fabricated value" discipline `MotionAxis.Result.gap`
    /// applies to a missing point.
    public static func centralDifference(_ samples: [RepSignal.Sample]) -> [VelocitySample] {
        guard samples.count >= 3 else { return [] }
        var result: [VelocitySample] = []
        result.reserveCapacity(samples.count - 2)
        for i in 1..<(samples.count - 1) {
            let h1 = samples[i].t - samples[i - 1].t
            let h2 = samples[i + 1].t - samples[i].t
            guard h1.isFinite, h2.isFinite, h1 > 0, h2 > 0 else { continue }

            // Unequally-spaced 3-point central difference, 2nd-order
            // accurate regardless of the h1/h2 ratio — see file doc.
            let a = -h2 / (h1 * (h1 + h2))
            let b = (h2 - h1) / (h1 * h2)
            let c = h1 / (h2 * (h1 + h2))
            let v = a * samples[i - 1].x + b * samples[i].x + c * samples[i + 1].x
            result.append(VelocitySample(t: samples[i].t, v: v))
        }
        return result
    }
}

// MARK: - One Euro filter (1D, off by default)

/// A One Euro filter (Casiez, Roussel & Vogel, CHI 2012) over a single
/// scalar stream (this task item 3). See this file's top-level doc, "Why
/// the One Euro filter is a separate, off-by-default step", for why this
/// exists as a standalone opt-in type rather than something the default
/// conditioning path ever calls implicitly.
///
/// Standard formulation: the derivative of the input is itself low-pass
/// filtered at a fixed `derivativeCutoff`, and that filtered speed adapts
/// the position filter's own cutoff — `minCutoff` at rest, rising by `beta`
/// per unit of filtered speed — so the filter is stiffer (less lag) during
/// fast motion and smoother (less jitter) when nearly still.
public struct OneEuroFilter: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// Minimum cutoff frequency, Hz — the filter's stiffness at zero
        /// speed. Lower removes more jitter but adds more lag at rest.
        public var minCutoff: Double
        /// How much the cutoff rises per unit of filtered speed. `0` means
        /// a plain fixed-cutoff low-pass (no speed adaptation at all).
        public var beta: Double
        /// Cutoff frequency, Hz, for the internal derivative low-pass.
        public var derivativeCutoff: Double

        /// `minCutoff: 1.0, beta: 0.0, derivativeCutoff: 1.0` — the
        /// reference implementation's own neutral starting point (Casiez et
        /// al.'s example code), not a value tuned for this signal. This
        /// task deliberately does not tune One Euro parameters for pose or
        /// plate-track noise: SPEC §4.1 is explicit that whether smoothing
        /// is needed at all is an open question `--jitter-report` (this
        /// task item 4) answers from data, and this type's whole point is
        /// to exist and be off by default until that data says otherwise
        /// (W3-02 or later, once real backends and real static-hold footage
        /// exist).
        public init(
            minCutoff: Double = OneEuroFilter.defaultMinCutoff,
            beta: Double = OneEuroFilter.defaultBeta,
            derivativeCutoff: Double = OneEuroFilter.defaultDerivativeCutoff
        ) {
            precondition(minCutoff.isFinite && minCutoff > 0, "OneEuroFilter.Configuration.minCutoff must be finite and positive")
            precondition(beta.isFinite && beta >= 0, "OneEuroFilter.Configuration.beta must be finite and non-negative")
            precondition(
                derivativeCutoff.isFinite && derivativeCutoff > 0,
                "OneEuroFilter.Configuration.derivativeCutoff must be finite and positive"
            )
            self.minCutoff = minCutoff
            self.beta = beta
            self.derivativeCutoff = derivativeCutoff
        }
    }

    public static let defaultMinCutoff: Double = 1.0
    public static let defaultBeta: Double = 0.0
    public static let defaultDerivativeCutoff: Double = 1.0

    public let configuration: Configuration
    private var initialized = false
    private var previousFilteredX: Double = 0
    private var previousFilteredDerivative: Double = 0
    private var previousT: TimeInterval = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public static func == (lhs: OneEuroFilter, rhs: OneEuroFilter) -> Bool {
        lhs.configuration == rhs.configuration
            && lhs.initialized == rhs.initialized
            && lhs.previousFilteredX == rhs.previousFilteredX
            && lhs.previousFilteredDerivative == rhs.previousFilteredDerivative
            && lhs.previousT == rhs.previousT
    }

    /// Advances by one sample, in capture order, and returns the filtered
    /// value. The very first call has no prior state to filter against and
    /// returns `x` unchanged, which is the only sane behaviour with zero
    /// history — matching `MotionAxis`'s "no fabricated value from
    /// insufficient data" discipline.
    ///
    /// A non-advancing or out-of-order `t` (`dt <= 0`) has no real rate to
    /// filter against either; rather than divide by a bogus `dt`, this
    /// leaves the filter's internal state untouched and returns `x`
    /// unfiltered for that call.
    public mutating func filter(t: TimeInterval, x: Double) -> Double {
        guard initialized else {
            initialized = true
            previousFilteredX = x
            previousFilteredDerivative = 0
            previousT = t
            return x
        }

        let dt = t - previousT
        guard dt.isFinite, dt > 0 else { return x }

        let rawDerivative = (x - previousFilteredX) / dt
        let filteredDerivative = Self.lowPass(
            rawDerivative,
            previous: previousFilteredDerivative,
            alpha: Self.alpha(cutoff: configuration.derivativeCutoff, dt: dt)
        )
        let cutoff = configuration.minCutoff + configuration.beta * abs(filteredDerivative)
        let filteredX = Self.lowPass(x, previous: previousFilteredX, alpha: Self.alpha(cutoff: cutoff, dt: dt))

        previousFilteredX = filteredX
        previousFilteredDerivative = filteredDerivative
        previousT = t
        return filteredX
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    private static func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}

// MARK: - Composed pipeline

/// The composed conditioning pipeline (this task's full scope, item by
/// item): optional smoothing → rolling-median detrend → central-difference
/// derivative. This is what W3-02's counter is expected to call; see this
/// file's top-level doc for why this stops short of being "the counter"
/// itself.
public enum SignalConditioningPipeline {
    public struct Configuration: Sendable, Equatable {
        public var detrendWindowSeconds: Double
        /// One Euro filter configuration, applied to the raw `x` signal
        /// before detrending. `nil` — the default — means the filter step
        /// is skipped entirely, not run with neutral parameters; see this
        /// file's top-level doc, "Why the One Euro filter is a separate,
        /// off-by-default step".
        public var smoothing: OneEuroFilter.Configuration?

        public init(
            detrendWindowSeconds: Double = RollingMedianDetrend.defaultWindowSeconds,
            smoothing: OneEuroFilter.Configuration? = nil
        ) {
            self.detrendWindowSeconds = detrendWindowSeconds
            self.smoothing = smoothing
        }
    }

    /// Runs the pipeline over a full sample array (see
    /// `RollingMedianDetrend.detrend` and `Derivative.centralDifference`,
    /// which this composes and which each remain independently usable and
    /// independently tested).
    public static func condition(
        _ samples: [RepSignal.Sample],
        configuration: Configuration = Configuration()
    ) -> (detrended: [RepSignal.Sample], velocity: [VelocitySample]) {
        var working = samples
        if let smoothing = configuration.smoothing {
            var filter = OneEuroFilter(configuration: smoothing)
            working = samples.map { sample in
                RepSignal.Sample(t: sample.t, x: filter.filter(t: sample.t, x: sample.x), confidence: sample.confidence)
            }
        }
        let detrended = RollingMedianDetrend.detrend(working, windowSeconds: configuration.detrendWindowSeconds)
        let velocity = Derivative.centralDifference(detrended)
        return (detrended, velocity)
    }
}

// MARK: - Jitter measurement

/// The numbers `--jitter-report` (`timmethod-eval`, a different file) is
/// built around (this task item 4): noise amplitude in metres, and — when a
/// caller supplies a known rep amplitude to compare against — the ratio
/// that actually decides whether smoothing is worth its lag cost. See
/// `JitterAnalysis.measure` for how these are computed and
/// `timmethod-eval`'s `JitterReport.swift` for the CLI-side scope note
/// about what this can and cannot claim today (no pose backend, no real
/// static-hold footage yet).
public struct JitterMeasurement: Sendable, Equatable {
    public let sampleCount: Int
    public let durationSeconds: Double
    /// Mean of the detrended signal, metres. Near zero on a genuinely
    /// static hold is the expected sanity signature of a working detrend;
    /// far from zero suggests the input isn't actually a static hold, or
    /// the detrend window is mis-sized for it.
    public let meanMetres: Double
    /// Population standard deviation of the detrended signal, metres.
    public let standardDeviationMetres: Double
    /// Peak-to-peak (max − min) of the detrended signal, metres. Compared
    /// directly against a rep's own peak-to-valley amplitude (SPEC §7.2
    /// phrases the amplitude gate itself as "peak-to-valley amplitude ≥
    /// A_min") — this is the apples-to-apples number, not the standard
    /// deviation.
    public let peakToPeakMetres: Double
    /// Echo of whatever `repAmplitudeReferenceMetres` `measure(_:...)` was
    /// called with, or `nil` if none was supplied.
    public let repAmplitudeReferenceMetres: Double?
    /// `peakToPeakMetres / repAmplitudeReferenceMetres`, or `nil` when no
    /// reference was supplied. This ratio, not the raw jitter number alone,
    /// is what determines whether smoothing is worth its lag cost — a
    /// jitter floor that's 1% of a rep's swept range is noise the amplitude
    /// gate (SPEC §7.2) already rejects for free; one that's 30% is a real
    /// problem no amplitude threshold can safely absorb.
    public let jitterToRepAmplitudeRatio: Double?
}

public enum JitterAnalysis {
    /// Measures noise on a (presumed static-subject) sample sequence.
    /// Detrends with `RollingMedianDetrend` first — the same conditioning
    /// stage the counter runs — so a static-hold clip that isn't *perfectly*
    /// still (a slight sway, a slow camera settle) doesn't get its real
    /// jitter floor inflated by that drift; what's measured is noise *after*
    /// the conditioning the counter will actually apply, which is the
    /// number that matters for deciding whether more smoothing is needed on
    /// top of it.
    ///
    /// Returns `nil` for fewer than 2 samples — not enough to measure
    /// anything from.
    public static func measure(
        _ samples: [RepSignal.Sample],
        detrendWindowSeconds: Double = RollingMedianDetrend.defaultWindowSeconds,
        repAmplitudeReferenceMetres: Double? = nil
    ) -> JitterMeasurement? {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return nil }

        let detrended = RollingMedianDetrend.detrend(samples, windowSeconds: detrendWindowSeconds)
        let values = detrended.map(\.x)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let standardDeviation = variance.squareRoot()
        let peakToPeak = (values.max() ?? 0) - (values.min() ?? 0)

        let ratio: Double? = {
            guard let reference = repAmplitudeReferenceMetres, reference > 0 else { return nil }
            return peakToPeak / reference
        }()

        return JitterMeasurement(
            sampleCount: samples.count,
            durationSeconds: last.t - first.t,
            meanMetres: mean,
            standardDeviationMetres: standardDeviation,
            peakToPeakMetres: peakToPeak,
            repAmplitudeReferenceMetres: (repAmplitudeReferenceMetres.map { $0 > 0 } == true) ? repAmplitudeReferenceMetres : nil,
            jitterToRepAmplitudeRatio: ratio
        )
    }
}
