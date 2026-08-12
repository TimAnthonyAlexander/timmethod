import Foundation
import TimMethodCore

/// Renders an `EvalReport` as a plain, aligned terminal table (SPEC §15:
/// "readable terminal table" — "the table is what gets looked at fifty
/// times a day"). No box-drawing characters, no colour — just consistent
/// column widths and a plain-dash rule, which stays legible piped through
/// `less`, redirected to a log file, or pasted into a doc.
enum TerminalTable {
    static func render(_ report: EvalReport) -> String {
        var lines: [String] = []

        lines.append("timmethod-eval report")
        lines.append(pad("  provider:", 22) + report.provider)
        lines.append(pad("  fixtures:", 22) + report.fixturesDirectory)
        if let filter = report.filter {
            lines.append(pad("  filter:", 22) + filter)
        }
        lines.append(pad("  pacing:", 22) + (report.realtime ? "realtime" : "as-fast-as-possible"))
        lines.append(pad("  clips scored:", 22) + String(report.clips.count))
        if !report.skippedFixtures.isEmpty {
            lines.append(pad("  clips skipped:", 22) + String(report.skippedFixtures.count))
        }
        lines.append("")

        if !report.clips.isEmpty {
            lines.append(contentsOf: clipTable(report.clips))
            lines.append("")
        }

        if !report.skippedFixtures.isEmpty {
            lines.append("Skipped:")
            for issue in report.skippedFixtures {
                lines.append("  - " + issue)
            }
            lines.append("")
        }

        lines.append(contentsOf: aggregateSection(report.aggregate))
        lines.append("")
        lines.append(contentsOf: gateSection(report.gate))

        return lines.joined(separator: "\n")
    }

    // MARK: - Per-clip table

    private static func clipTable(_ clips: [ClipEvaluation]) -> [String] {
        let headers = ["CLIP", "EXERCISE", "EQUIP", "CAMERA", "TRUE", "PRED", "DELTA", "FP", "FN", "BASIS", "STATUS"]
        var rows: [[String]] = []
        for clip in clips {
            rows.append([
                clip.name,
                clip.exerciseId,
                clip.equipment.rawValue,
                clip.cameraPosition.rawValue,
                String(clip.trueCount),
                String(clip.predictedCount),
                signedString(clip.delta),
                String(clip.falsePositiveCount),
                String(clip.falseNegativeCount),
                clip.fpFnBasis == .timestampMatched ? "timestamp" : "count-only",
                clip.isCountCorrect ? "OK" : (clip.isWithinOffByOne ? "OFF-BY-ONE" : "WRONG"),
            ])
        }
        return table(headers: headers, rows: rows, rightAlign: [4, 5, 6, 7, 8])
    }

    // MARK: - Aggregate

    private static func aggregateSection(_ aggregate: AggregateEvaluation) -> [String] {
        var lines = ["Aggregate (\(aggregate.clipCount) clip\(aggregate.clipCount == 1 ? "" : "s")):"]
        lines.append("  " + metricLine("Count MAE, overall", aggregate.countMAEOverall, formatter: fixed3))
        lines.append("  " + metricLine("Count MAE, loaded", aggregate.countMAELoaded, formatter: fixed3))
        lines.append("  " + metricLine("Count MAE, bodyweight", aggregate.countMAEBodyweight, formatter: fixed3))
        lines.append("  " + metricLine("Off-by-one accuracy, overall", aggregate.offByOneAccuracyOverall, formatter: percent))
        lines.append("  " + metricLine("Off-by-one accuracy, loaded", aggregate.offByOneAccuracyLoaded, formatter: percent))
        lines.append("  " + metricLine("False positives / session", aggregate.falsePositivesPerSession, formatter: fixed3))

        if !aggregate.perExercise.isEmpty {
            lines.append("")
            lines.append("  By exercise:")
            let headers = ["EXERCISE", "CLIPS", "MAE", "OFF-BY-1", "MEAN FP", "MEAN FN"]
            let rows = aggregate.perExercise.map { row -> [String] in
                [
                    row.exerciseId,
                    String(row.clipCount),
                    fixed3(row.countMAE.value),
                    percent(row.offByOneAccuracy.value),
                    fixed3(row.meanFalsePositives.value),
                    fixed3(row.meanFalseNegatives.value),
                ]
            }
            lines.append(contentsOf: table(headers: headers, rows: rows, rightAlign: [1, 2, 3, 4, 5]).map { "  " + $0 })
        }

        if !aggregate.perCameraPosition.isEmpty {
            lines.append("")
            lines.append("  By camera angle:")
            let headers = ["CAMERA", "DEGREES", "CLIPS", "MAE", "OFF-BY-1"]
            let rows = aggregate.perCameraPosition.map { row -> [String] in
                [
                    row.cameraPosition.rawValue,
                    fixed1(row.degreesOffPerpendicular),
                    String(row.clipCount),
                    fixed3(row.countMAE.value),
                    percent(row.offByOneAccuracy.value),
                ]
            }
            lines.append(contentsOf: table(headers: headers, rows: rows, rightAlign: [1, 2, 3, 4]).map { "  " + $0 })
        }

        return lines
    }

    private static func metricLine(_ name: String, _ metric: Metric?, formatter: (Double) -> String) -> String {
        guard let metric else {
            return pad(name + ":", 32) + "not evaluated (no data)"
        }
        return pad(name + ":", 32) + formatter(metric.value) + "  (n=\(metric.sampleCount))"
    }

    // MARK: - Gate

    private static func gateSection(_ gate: GateResult) -> [String] {
        var lines = ["Regression gate (SPEC §15.2 floors) — \(gate.passed ? "PASS" : "FAIL"):"]
        let headers = ["METRIC", "FLOOR", "OBSERVED", "STATUS"]
        let rows = gate.checks.map { check -> [String] in
            [
                check.metric,
                check.floorDescription,
                check.observed.map(fixed3) ?? "-",
                statusLabel(check.status),
            ]
        }
        lines.append(contentsOf: table(headers: headers, rows: rows, rightAlign: [2]).map { "  " + $0 })
        return lines
    }

    private static func statusLabel(_ status: GateStatus) -> String {
        switch status {
        case .pass: "PASS"
        case .fail: "FAIL"
        case .skippedNoData: "SKIPPED (no data)"
        }
    }

    // MARK: - Generic table rendering

    /// Left-aligns text columns, right-aligns the columns named in
    /// `rightAlign` (by index), separates the header from data with a
    /// plain dash rule sized to the table's own width. No Unicode
    /// box-drawing.
    private static func table(headers: [String], rows: [[String]], rightAlign: Set<Int>) -> [String] {
        guard !rows.isEmpty else { return [] }
        let columnCount = headers.count
        var widths = headers.map { $0.count }
        for row in rows {
            for index in 0..<columnCount where index < row.count {
                widths[index] = max(widths[index], row[index].count)
            }
        }

        func formatRow(_ cells: [String]) -> String {
            var parts: [String] = []
            for index in 0..<columnCount {
                let cell = index < cells.count ? cells[index] : ""
                let width = widths[index]
                if rightAlign.contains(index) {
                    parts.append(String(repeating: " ", count: max(0, width - cell.count)) + cell)
                } else {
                    parts.append(cell + String(repeating: " ", count: max(0, width - cell.count)))
                }
            }
            return parts.joined(separator: "  ")
        }

        var lines = [formatRow(headers)]
        let totalWidth = widths.reduce(0, +) + 2 * (columnCount - 1)
        lines.append(String(repeating: "-", count: totalWidth))
        for row in rows {
            lines.append(formatRow(row))
        }
        return lines
    }

    // MARK: - Formatting helpers

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func signedString(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }

    private static func fixed3(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func fixed1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
