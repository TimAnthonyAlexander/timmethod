import Foundation

/// A fixture whose sidecar decoded and validated cleanly, paired with the
/// video file it describes.
public struct LoadedFixture: Sendable, Equatable {
    public let videoURL: URL
    public let sidecarURL: URL
    public let fixture: Fixture

    public init(videoURL: URL, sidecarURL: URL, fixture: Fixture) {
        self.videoURL = videoURL
        self.sidecarURL = sidecarURL
        self.fixture = fixture
    }
}

/// The result of walking a fixtures directory (`FixtureLoader.load(directory:)`).
///
/// One bad fixture must never abort a batch run — a 200-clip scoring pass
/// has to keep going and still return the 199 good ones. `issues` is where
/// the skipped, offending ones are reported; `fixtures` is what a caller
/// actually scores against.
public struct FixtureLoadResult: Sendable, Equatable {
    public let fixtures: [LoadedFixture]
    public let issues: [FixtureLoadError]

    public init(fixtures: [LoadedFixture], issues: [FixtureLoadError]) {
        self.fixtures = fixtures
        self.issues = issues
    }
}

/// Directory-level failures — the directory itself is missing or
/// unreadable. Distinct from `FixtureLoadError`, which is always about one
/// specific fixture within an otherwise-readable directory.
public enum FixtureLoaderError: Error, Sendable, Equatable, CustomStringConvertible {
    case directoryNotFound(URL)
    case directoryUnreadable(url: URL, underlying: String)

    public var description: String {
        switch self {
        case .directoryNotFound(let url):
            "fixtures directory not found: \(url.path)"
        case .directoryUnreadable(let url, let underlying):
            "fixtures directory unreadable: \(url.path) (\(underlying))"
        }
    }
}

/// Everything that can be wrong with one fixture (a `.json` sidecar plus
/// its paired `.mov`). Every case names the offending file and states what
/// is wrong with it — per the task brief, a malformed sidecar must produce
/// a useful, specific error, never a crash and never a generic "invalid
/// fixture" message that sends someone back to re-read the whole file to
/// find out why.
public enum FixtureLoadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A `.mov` exists with no matching `.json` sidecar.
    case missingSidecar(video: URL)
    /// A `.json` sidecar exists with no matching `.mov`.
    case missingVideo(sidecar: URL)
    /// The sidecar could not be read from disk or decoded as `Fixture`
    /// JSON. Covers a missing/unreadable file, invalid JSON syntax, and
    /// JSON that doesn't match the schema (wrong types, unknown enum raw
    /// value, missing required key) — `underlying` carries the decoder's
    /// own diagnostic.
    case malformedJSON(sidecar: URL, underlying: any Error)
    case negativeRepCount(sidecar: URL, value: Int)
    case negativePartialCount(sidecar: URL, value: Int)
    case partialExceedsTotal(sidecar: URL, partial: Int, total: Int)
    /// `perRepTimestamps[atIndex]` is not strictly greater than the entry
    /// before it.
    case nonMonotonicRepTimestamps(sidecar: URL, atIndex: Int, previous: TimeInterval, current: TimeInterval)
    case plateDiameterOnBodyweight(sidecar: URL, mm: Double)
    /// `plateDiameterMm` is present but not a positive number.
    case invalidPlateDiameter(sidecar: URL, mm: Double)
    /// `referenceMeanConcentricVelocity[atIndex]` is not a positive number
    /// — concentric motion is positive by the `RepSignal.Sample.x` sign
    /// convention (SPEC §6), so zero or negative is mislabelled, not a real
    /// measurement.
    case invalidReferenceVelocity(sidecar: URL, atIndex: Int, value: Double)
    /// `trueSetBoundaries[atIndex].endTime` is not strictly after `startTime`.
    case invalidSetBoundary(sidecar: URL, atIndex: Int, startTime: TimeInterval, endTime: TimeInterval)
    /// `trueSetBoundaries[atIndex]` starts before the previous boundary's
    /// `endTime` — overlapping or out-of-order sets.
    case overlappingSetBoundaries(sidecar: URL, atIndex: Int)

    public var description: String {
        switch self {
        case .missingSidecar(let video):
            "fixture \(video.lastPathComponent): no matching .json sidecar next to this video"
        case .missingVideo(let sidecar):
            "fixture \(sidecar.lastPathComponent): no matching .mov video next to this sidecar"
        case .malformedJSON(let sidecar, let underlying):
            "fixture \(sidecar.lastPathComponent): malformed sidecar JSON — \(underlying)"
        case .negativeRepCount(let sidecar, let value):
            "fixture \(sidecar.lastPathComponent): trueRepCount is negative (\(value))"
        case .negativePartialCount(let sidecar, let value):
            "fixture \(sidecar.lastPathComponent): truePartialCount is negative (\(value))"
        case .partialExceedsTotal(let sidecar, let partial, let total):
            "fixture \(sidecar.lastPathComponent): truePartialCount (\(partial)) exceeds trueRepCount (\(total))"
        case .nonMonotonicRepTimestamps(let sidecar, let atIndex, let previous, let current):
            "fixture \(sidecar.lastPathComponent): perRepTimestamps[\(atIndex)] (\(current)) does not come after perRepTimestamps[\(atIndex - 1)] (\(previous)) — must be strictly increasing"
        case .plateDiameterOnBodyweight(let sidecar, let mm):
            "fixture \(sidecar.lastPathComponent): plateDiameterMm (\(mm)) set on a .bodyweight exercise — there is no plate to measure"
        case .invalidPlateDiameter(let sidecar, let mm):
            "fixture \(sidecar.lastPathComponent): plateDiameterMm (\(mm)) must be positive"
        case .invalidReferenceVelocity(let sidecar, let atIndex, let value):
            "fixture \(sidecar.lastPathComponent): referenceMeanConcentricVelocity[\(atIndex)] (\(value)) must be positive"
        case .invalidSetBoundary(let sidecar, let atIndex, let startTime, let endTime):
            "fixture \(sidecar.lastPathComponent): trueSetBoundaries[\(atIndex)] endTime (\(endTime)) is not after startTime (\(startTime))"
        case .overlappingSetBoundaries(let sidecar, let atIndex):
            "fixture \(sidecar.lastPathComponent): trueSetBoundaries[\(atIndex)] overlaps or precedes the previous boundary"
        }
    }

    public static func == (lhs: FixtureLoadError, rhs: FixtureLoadError) -> Bool {
        switch (lhs, rhs) {
        case (.missingSidecar(let a), .missingSidecar(let b)):
            a == b
        case (.missingVideo(let a), .missingVideo(let b)):
            a == b
        case (.malformedJSON(let au, _), .malformedJSON(let bu, _)):
            au == bu
        case (.negativeRepCount(let au, let av), .negativeRepCount(let bu, let bv)):
            au == bu && av == bv
        case (.negativePartialCount(let au, let av), .negativePartialCount(let bu, let bv)):
            au == bu && av == bv
        case (.partialExceedsTotal(let au, let ap, let at), .partialExceedsTotal(let bu, let bp, let bt)):
            au == bu && ap == bp && at == bt
        case (
            .nonMonotonicRepTimestamps(let au, let ai, let ap, let ac),
            .nonMonotonicRepTimestamps(let bu, let bi, let bp, let bc)
        ):
            au == bu && ai == bi && ap == bp && ac == bc
        case (.plateDiameterOnBodyweight(let au, let am), .plateDiameterOnBodyweight(let bu, let bm)):
            au == bu && am == bm
        case (.invalidPlateDiameter(let au, let am), .invalidPlateDiameter(let bu, let bm)):
            au == bu && am == bm
        case (.invalidReferenceVelocity(let au, let ai, let av), .invalidReferenceVelocity(let bu, let bi, let bv)):
            au == bu && ai == bi && av == bv
        case (
            .invalidSetBoundary(let au, let ai, let ast, let aet),
            .invalidSetBoundary(let bu, let bi, let bst, let bet)
        ):
            au == bu && ai == bi && ast == bst && aet == bet
        case (.overlappingSetBoundaries(let au, let ai), .overlappingSetBoundaries(let bu, let bi)):
            au == bu && ai == bi
        default:
            false
        }
    }
}

/// Walks a fixtures directory, pairs `.mov` clips with `.json` sidecars,
/// decodes and validates each sidecar against the `Fixture` schema (SPEC
/// §15).
///
/// Never crashes on a malformed sidecar and never aborts a batch: a bad
/// fixture is reported in `FixtureLoadResult.issues` and skipped, so a
/// 200-clip directory with one broken sidecar still returns the other 199.
public enum FixtureLoader {
    /// Loads and validates every fixture in `directory`. `.json` files with
    /// no matching `.mov`, `.mov` files with no matching `.json`, and
    /// sidecars that fail to decode or validate are all collected into
    /// `FixtureLoadResult.issues` rather than thrown — only a problem with
    /// the directory itself (missing, unreadable) throws.
    public static func load(directory: URL) throws -> FixtureLoadResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FixtureLoaderError.directoryNotFound(directory)
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw FixtureLoaderError.directoryUnreadable(url: directory, underlying: String(describing: error))
        }

        let jsonBaseNames = Set(
            contents.filter { $0.pathExtension.lowercased() == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        let movBaseNames = Set(
            contents.filter { $0.pathExtension.lowercased() == "mov" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        let allBaseNames = jsonBaseNames.union(movBaseNames).sorted()

        var fixtures: [LoadedFixture] = []
        var issues: [FixtureLoadError] = []

        for baseName in allBaseNames {
            let sidecarURL = directory.appendingPathComponent(baseName).appendingPathExtension("json")
            let videoURL = directory.appendingPathComponent(baseName).appendingPathExtension("mov")

            guard jsonBaseNames.contains(baseName) else {
                issues.append(.missingSidecar(video: videoURL))
                continue
            }
            guard movBaseNames.contains(baseName) else {
                issues.append(.missingVideo(sidecar: sidecarURL))
                continue
            }

            do {
                fixtures.append(try loadFixture(sidecarURL: sidecarURL, videoURL: videoURL))
            } catch let error as FixtureLoadError {
                issues.append(error)
            }
        }

        return FixtureLoadResult(fixtures: fixtures, issues: issues)
    }

    /// Decodes and validates a single sidecar. Used by `load(directory:)`
    /// internally, and exposed directly so a caller (or a test) can load
    /// one known fixture without walking a whole directory.
    public static func loadFixture(sidecarURL: URL, videoURL: URL) throws -> LoadedFixture {
        let data: Data
        do {
            data = try Data(contentsOf: sidecarURL)
        } catch {
            throw FixtureLoadError.malformedJSON(sidecar: sidecarURL, underlying: error)
        }

        let fixture: Fixture
        do {
            fixture = try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw FixtureLoadError.malformedJSON(sidecar: sidecarURL, underlying: error)
        }

        try validate(fixture, sidecar: sidecarURL)

        return LoadedFixture(videoURL: videoURL, sidecarURL: sidecarURL, fixture: fixture)
    }

    /// Validates a decoded `Fixture` in isolation, with no filesystem
    /// access — `sidecar` is used only to name the offending file in the
    /// thrown error. Exposed publicly so validation rules can be tested
    /// directly against in-memory fixtures, without writing files to disk.
    public static func validate(_ fixture: Fixture, sidecar: URL) throws {
        guard fixture.trueRepCount >= 0 else {
            throw FixtureLoadError.negativeRepCount(sidecar: sidecar, value: fixture.trueRepCount)
        }
        guard fixture.truePartialCount >= 0 else {
            throw FixtureLoadError.negativePartialCount(sidecar: sidecar, value: fixture.truePartialCount)
        }
        guard fixture.truePartialCount <= fixture.trueRepCount else {
            throw FixtureLoadError.partialExceedsTotal(
                sidecar: sidecar,
                partial: fixture.truePartialCount,
                total: fixture.trueRepCount
            )
        }

        if let plateDiameterMm = fixture.plateDiameterMm {
            guard fixture.equipment != .bodyweight else {
                throw FixtureLoadError.plateDiameterOnBodyweight(sidecar: sidecar, mm: plateDiameterMm)
            }
            guard plateDiameterMm > 0 else {
                throw FixtureLoadError.invalidPlateDiameter(sidecar: sidecar, mm: plateDiameterMm)
            }
        }

        if let timestamps = fixture.perRepTimestamps, timestamps.count > 1 {
            for index in 1..<timestamps.count {
                guard timestamps[index] > timestamps[index - 1] else {
                    throw FixtureLoadError.nonMonotonicRepTimestamps(
                        sidecar: sidecar,
                        atIndex: index,
                        previous: timestamps[index - 1],
                        current: timestamps[index]
                    )
                }
            }
        }

        if let velocities = fixture.referenceMeanConcentricVelocity {
            for (index, velocity) in velocities.enumerated() {
                guard velocity > 0 else {
                    throw FixtureLoadError.invalidReferenceVelocity(sidecar: sidecar, atIndex: index, value: velocity)
                }
            }
        }

        if let boundaries = fixture.trueSetBoundaries {
            var previousEndTime: TimeInterval?
            for (index, boundary) in boundaries.enumerated() {
                guard boundary.endTime > boundary.startTime else {
                    throw FixtureLoadError.invalidSetBoundary(
                        sidecar: sidecar,
                        atIndex: index,
                        startTime: boundary.startTime,
                        endTime: boundary.endTime
                    )
                }
                if let previousEndTime, boundary.startTime < previousEndTime {
                    throw FixtureLoadError.overlappingSetBoundaries(sidecar: sidecar, atIndex: index)
                }
                previousEndTime = boundary.endTime
            }
        }
    }
}
