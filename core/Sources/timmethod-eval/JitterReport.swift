import Foundation
import TimMethodCore

/// CLI-side plumbing for `timmethod-eval --jitter-report` (W3-01 item 4;
/// SPEC §4.1, §7.2). All the actual jitter arithmetic —
/// `TimMethodCore.JitterAnalysis` / `JitterMeasurement`, built on
/// `RollingMedianDetrend` — lives in `Counter/SignalConditioning.swift` and
/// is unit-tested there (`SignalConditioningTests`) without spawning this
/// process. This file only reads the `--signal` input file, calls into
/// that, and formats the result for a terminal and for `--report`'s JSON
/// output.
///
/// ## Scope — read this before extending
///
/// SPEC §4.1 and this task's own Done-when ask for jitter "quantified for
/// each backend." Neither survives contact with what actually exists today:
///
/// - No `PoseProvider` implementation exists yet — both Apple Vision 3D and
///   MediaPipe are Wave 5.
/// - No real static-subject footage exists yet — W1-06 (capturing it) is
///   still an open task; the only committed fixture clips
///   (`fixtures/*.mov`) are synthetic solid-colour placeholder frames
///   written for `FixtureLoader` schema testing, not real static holds, and
///   running them through the Wave-1 placeholder signal path
///   (`FrameReplay.buildPlaceholderSignal`) produces a constant `x = 0`
///   trace with no real jitter in it at all — a meaningless input for this
///   mode.
///
/// So this mode measures whatever `--signal` is pointed at, and reports
/// real, honestly-computed numbers on that input — it does not compare
/// backends, and it does not stand in a fabricated "Apple Vision vs
/// MediaPipe" number for the comparison SPEC eventually wants. That
/// comparison becomes possible once Wave 5 lands a `PoseProvider` and W1-06
/// lands real static-hold clips; at that point, whatever wires those into a
/// `RepSignal` can hand the result straight to `JitterAnalysis.measure`
/// unchanged — this file's read/format layer and the CLI's `--signal`
/// input format are a stopgap for *today*, not a design that needs to be
/// thrown away later.
enum JitterReportError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case decodeFailed(path: String, underlying: any Error)
    case tooFewSamples(path: String, count: Int)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            "timmethod-eval: --signal file not found: \(path)"
        case .decodeFailed(let path, let underlying):
            "timmethod-eval: could not decode --signal file \(path) as a JSON array of {\"t\": seconds, \"x\": metres[, \"confidence\": 0...1]} objects: \(underlying)"
        case .tooFewSamples(let path, let count):
            "timmethod-eval: --signal file \(path) has \(count) sample(s); at least 2 are required to measure jitter"
        }
    }
}

/// One `{t, x[, confidence]}` entry in a `--signal` input file. `t` and `x`
/// follow `RepSignal.Sample`'s own convention (seconds / metres,
/// `Signal/RepSignal.swift`, not modified by this task) — this type exists
/// only because `Sample` itself has no `Codable` conformance and `Signal/`
/// is off limits to this task, mirroring `TraceDumper`'s identical
/// precedent for the same reason.
struct JitterSignalSample: Decodable {
    let t: Double
    let x: Double
    let confidence: Double?
}

/// A `JitterMeasurement` mirrored into a `Codable` shape for `--report`'s
/// JSON output — `JitterMeasurement` itself has no `Codable` conformance
/// (it doesn't need one inside `TimMethodCore`; this CLI is the only
/// consumer that serialises it).
struct JitterMeasurementReport: Codable {
    let sampleCount: Int
    let durationSeconds: Double
    let meanMetres: Double
    let standardDeviationMetres: Double
    let peakToPeakMetres: Double
    let repAmplitudeReferenceMetres: Double?
    let jitterToRepAmplitudeRatio: Double?

    init(_ measurement: JitterMeasurement) {
        sampleCount = measurement.sampleCount
        durationSeconds = measurement.durationSeconds
        meanMetres = measurement.meanMetres
        standardDeviationMetres = measurement.standardDeviationMetres
        peakToPeakMetres = measurement.peakToPeakMetres
        repAmplitudeReferenceMetres = measurement.repAmplitudeReferenceMetres
        jitterToRepAmplitudeRatio = measurement.jitterToRepAmplitudeRatio
    }
}

/// What `--jitter-report` writes to `--report` (when supplied) and renders
/// to the terminal unconditionally.
struct JitterCLIReport: Codable {
    let signalPath: String
    let generatedAt: Date
    let measurement: JitterMeasurementReport
    let scopeNote: String
}

enum JitterReportRunner {
    static let scopeNote = """
        Per-backend comparison deferred: no PoseProvider implementation exists yet (Wave 5), and no real \
        static-subject footage exists yet (W1-06 is still open). This report measures whatever --signal was \
        given, nothing more — see JitterReport.swift's doc comment for the full scope note.
        """

    static func run(signalPath: String, repAmplitudeReferenceMetres: Double?) throws -> JitterCLIReport {
        let url = URL(fileURLWithPath: signalPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw JitterReportError.fileNotFound(signalPath)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JitterReportError.decodeFailed(path: signalPath, underlying: error)
        }

        let inputs: [JitterSignalSample]
        do {
            inputs = try JSONDecoder().decode([JitterSignalSample].self, from: data)
        } catch {
            throw JitterReportError.decodeFailed(path: signalPath, underlying: error)
        }

        guard inputs.count >= 2 else {
            throw JitterReportError.tooFewSamples(path: signalPath, count: inputs.count)
        }

        let samples = inputs.map { RepSignal.Sample(t: $0.t, x: $0.x, confidence: $0.confidence ?? 1.0) }
        guard let measurement = JitterAnalysis.measure(samples, repAmplitudeReferenceMetres: repAmplitudeReferenceMetres) else {
            throw JitterReportError.tooFewSamples(path: signalPath, count: samples.count)
        }

        return JitterCLIReport(
            signalPath: signalPath,
            generatedAt: Date(),
            measurement: JitterMeasurementReport(measurement),
            scopeNote: scopeNote
        )
    }

    static func render(_ report: JitterCLIReport) -> String {
        var lines: [String] = []
        lines.append("timmethod-eval jitter report")
        lines.append(pad("  signal:") + report.signalPath)
        lines.append(pad("  samples:") + String(report.measurement.sampleCount))
        lines.append(pad("  duration:") + String(format: "%.2f s", report.measurement.durationSeconds))
        lines.append(pad("  mean (detrended):") + String(format: "%.5f m", report.measurement.meanMetres))
        lines.append(pad("  std dev (detrended):") + String(format: "%.5f m", report.measurement.standardDeviationMetres))
        lines.append(pad("  peak-to-peak (detrended):") + String(format: "%.5f m", report.measurement.peakToPeakMetres))
        if let reference = report.measurement.repAmplitudeReferenceMetres, let ratio = report.measurement.jitterToRepAmplitudeRatio {
            lines.append(pad("  rep amplitude reference:") + String(format: "%.4f m", reference))
            lines.append(pad("  jitter / rep amplitude:") + String(format: "%.4f (%.1f%% of a rep's swept range)", ratio, ratio * 100))
        } else {
            lines.append(
                pad("  jitter / rep amplitude:")
                    + "not computed — pass --rep-amplitude-reference-meters to compare against a real rep's peak-to-valley amplitude"
            )
        }
        lines.append("")
        lines.append(report.scopeNote)
        return lines.joined(separator: "\n")
    }

    private static func pad(_ label: String, to width: Int = 28) -> String {
        label.count >= width ? label + " " : label + String(repeating: " ", count: width - label.count)
    }
}
