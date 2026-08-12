import Foundation

/// The full output of one `timmethod-eval` run (SPEC §15): per-clip scores,
/// the aggregate rollup, the regression-gate verdict, and enough run
/// metadata to make a later diff between two reports meaningful. This is
/// what `--report` serializes to JSON; `timmethod-eval`'s terminal table is
/// a rendering of the same data, not a second source of truth.
public struct EvalReport: Sendable, Equatable, Codable {
    /// `PoseProviderKind.rawValue` (SPEC §4.1) — the harness records which
    /// provider a run used so results are attributable, but does not branch
    /// on it: the provider flag is meaningless until Wave 5's Track B
    /// lands, and every result in this run comes from the same
    /// Track-A/placeholder path regardless of what was passed here.
    public var provider: String
    public var fixturesDirectory: String
    public var filter: String?
    /// Whether frames were paced to the clip's real timing
    /// (`ReplayPacing.realtime`) rather than replayed as fast as possible.
    public var realtime: Bool
    public var generatedAt: Date

    public var clips: [ClipEvaluation]
    /// Human-readable description of every fixture that was skipped —
    /// either `FixtureLoader` rejected its sidecar, or replaying its video
    /// failed. Never silently dropped: a fixture that didn't get scored
    /// must be visible in the report, not just absent from `clips`.
    public var skippedFixtures: [String]

    public var aggregate: AggregateEvaluation
    public var gate: GateResult

    public init(
        provider: String,
        fixturesDirectory: String,
        filter: String?,
        realtime: Bool,
        generatedAt: Date,
        clips: [ClipEvaluation],
        skippedFixtures: [String],
        aggregate: AggregateEvaluation,
        gate: GateResult
    ) {
        self.provider = provider
        self.fixturesDirectory = fixturesDirectory
        self.filter = filter
        self.realtime = realtime
        self.generatedAt = generatedAt
        self.clips = clips
        self.skippedFixtures = skippedFixtures
        self.aggregate = aggregate
        self.gate = gate
    }
}
