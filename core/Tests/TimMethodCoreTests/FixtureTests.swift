import Foundation
import Testing

@testable import TimMethodCore

@Suite("Fixture")
struct FixtureTests {
    /// `fixtures/` at the repo root, resolved from this test file's own
    /// source location (`core/Tests/TimMethodCoreTests/FixtureTests.swift`)
    /// rather than the process's working directory, which `swift test`
    /// does not guarantee.
    static var repoFixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FixtureTests.swift -> TimMethodCoreTests
            .deletingLastPathComponent()  // -> Tests
            .deletingLastPathComponent()  // -> core
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("fixtures")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ string: String, to url: URL) throws {
        try string.write(to: url, atomically: true, encoding: .utf8)
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    private func encode(_ fixture: Fixture) throws -> String {
        let data = try JSONEncoder().encode(fixture)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - The three hand-made example fixtures

    @Test("the three example fixtures load and validate with no issues")
    func exampleFixturesLoadAndValidate() throws {
        let result = try FixtureLoader.load(directory: Self.repoFixturesDirectory)

        // Every fixture in the repo must validate, examples and real corpus
        // alike — that assertion is worth keeping as the corpus grows.
        #expect(result.issues.isEmpty)

        // Look the three examples up by FILENAME, not by exercise id. The
        // corpus under fixtures/<source>/ contains many clips sharing an id
        // (dozens of back_squat), so an id is not a key and a fixed total is
        // not a fact. Asserting either couples this test to whatever footage
        // happens to be downloaded.
        func example(_ name: String) throws -> LoadedFixture {
            try #require(
                result.fixtures.first { $0.videoURL.deletingPathExtension().lastPathComponent == name },
                "missing example fixture \(name)"
            )
        }

        let squat = try example("barbell_back_squat")
        #expect(squat.fixture.equipment == .barbell)
        #expect(squat.fixture.plateDiameterMm == 450)
        #expect(squat.fixture.cameraPosition == .perpendicular)
        #expect(squat.fixture.licence == .ownFootage)
        #expect(squat.fixture.trueSetBoundaries?.count == 1)

        let row = try example("dumbbell_row")
        #expect(row.fixture.equipment == .dumbbell)
        #expect(row.fixture.plateDiameterMm == nil)
        #expect(row.fixture.referenceMeanConcentricVelocity?.count == row.fixture.trueRepCount)

        let pushup = try example("bodyweight_pushup")
        #expect(pushup.fixture.equipment == .bodyweight)
        #expect(pushup.fixture.plateDiameterMm == nil)
        #expect(pushup.fixture.cameraPosition.isWithinRecommendedEnvelope == false)

        for loaded in result.fixtures {
            #expect(FileManager.default.fileExists(atPath: loaded.videoURL.path))
        }
    }

    // MARK: - CameraPosition / Licence enum semantics

    @Test("CameraPosition maps to explicit degrees, thresholded at the SPEC §14.3 30° envelope")
    func cameraPositionDegrees() {
        #expect(CameraPosition.perpendicular.degreesOffPerpendicular == 0)
        #expect(CameraPosition.oblique30.degreesOffPerpendicular == 30)
        #expect(CameraPosition.frontal90.degreesOffPerpendicular == 90)
        #expect(CameraPosition.perpendicular.isWithinRecommendedEnvelope)
        #expect(CameraPosition.oblique30.isWithinRecommendedEnvelope)
        #expect(!CameraPosition.oblique45.isWithinRecommendedEnvelope)
    }

    @Test("Licence.allowsCommercialUse is conservative for unverified and non-commercial sources")
    func licenceCommercialUse() {
        #expect(Licence.ccBy4.allowsCommercialUse)
        #expect(Licence.openUnrestricted.allowsCommercialUse)
        #expect(Licence.ownFootage.allowsCommercialUse)
        #expect(!Licence.ccByNcSa4.allowsCommercialUse)
        #expect(!Licence.nonCommercialGated.allowsCommercialUse)
        #expect(!Licence.unverifiedCommercialUse.allowsCommercialUse)
    }

    // MARK: - Round-trip

    @Test("a fully-populated Fixture round-trips through JSON losslessly")
    func fullFixtureRoundTrips() throws {
        let original = Fixture(
            exerciseId: "back_squat",
            equipment: .barbell,
            plateDiameterMm: 450,
            trueRepCount: 5,
            truePartialCount: 1,
            cameraPosition: .oblique15,
            lightingNote: "overhead LED",
            sourceDataset: "own",
            licence: .ownFootage,
            perRepTimestamps: [1.0, 2.5, 4.0, 5.5, 7.0],
            referenceMeanConcentricVelocity: [0.6, 0.58, 0.55, 0.5, 0.4],
            trueSetBoundaries: [Fixture.SetBoundary(startTime: 0, endTime: 8)]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Fixture.self, from: data)

        #expect(decoded == original)
    }

    @Test("a minimal Fixture with every optional field nil round-trips losslessly")
    func minimalFixtureRoundTrips() throws {
        let original = Fixture(
            exerciseId: "pushup",
            equipment: .bodyweight,
            trueRepCount: 8,
            cameraPosition: .oblique45,
            lightingNote: "dim lamp",
            sourceDataset: "own",
            licence: .ownFootage
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Fixture.self, from: data)

        #expect(decoded == original)
        #expect(decoded.plateDiameterMm == nil)
        #expect(decoded.perRepTimestamps == nil)
        #expect(decoded.referenceMeanConcentricVelocity == nil)
        #expect(decoded.trueSetBoundaries == nil)
    }

    // MARK: - Validation: each failure mode produces its specific error

    private func validFixture(
        equipment: Equipment = .barbell,
        plateDiameterMm: Double? = 450,
        trueRepCount: Int = 5,
        truePartialCount: Int = 0,
        perRepTimestamps: [TimeInterval]? = nil,
        referenceMeanConcentricVelocity: [Double]? = nil,
        trueSetBoundaries: [Fixture.SetBoundary]? = nil
    ) -> Fixture {
        Fixture(
            exerciseId: "test_exercise",
            equipment: equipment,
            plateDiameterMm: plateDiameterMm,
            trueRepCount: trueRepCount,
            truePartialCount: truePartialCount,
            cameraPosition: .perpendicular,
            lightingNote: "test",
            sourceDataset: "own",
            licence: .ownFootage,
            perRepTimestamps: perRepTimestamps,
            referenceMeanConcentricVelocity: referenceMeanConcentricVelocity,
            trueSetBoundaries: trueSetBoundaries
        )
    }

    @Test("negative trueRepCount throws .negativeRepCount naming the sidecar and the value")
    func negativeRepCountThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(trueRepCount: -1)
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .negativeRepCount")
        } catch FixtureLoadError.negativeRepCount(let url, let value) {
            #expect(url == sidecar)
            #expect(value == -1)
        } catch {
            Issue.record("expected .negativeRepCount, got \(error)")
        }
    }

    @Test("negative truePartialCount throws .negativePartialCount")
    func negativePartialCountThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(trueRepCount: 5, truePartialCount: -2)
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .negativePartialCount")
        } catch FixtureLoadError.negativePartialCount(let url, let value) {
            #expect(url == sidecar)
            #expect(value == -2)
        } catch {
            Issue.record("expected .negativePartialCount, got \(error)")
        }
    }

    @Test("truePartialCount exceeding trueRepCount throws .partialExceedsTotal")
    func partialExceedsTotalThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(trueRepCount: 3, truePartialCount: 4)
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .partialExceedsTotal")
        } catch FixtureLoadError.partialExceedsTotal(let url, let partial, let total) {
            #expect(url == sidecar)
            #expect(partial == 4)
            #expect(total == 3)
        } catch {
            Issue.record("expected .partialExceedsTotal, got \(error)")
        }
    }

    @Test("non-monotonic perRepTimestamps throws .nonMonotonicRepTimestamps at the offending index")
    func nonMonotonicTimestampsThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(perRepTimestamps: [1.0, 2.0, 1.9, 3.0])
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .nonMonotonicRepTimestamps")
        } catch FixtureLoadError.nonMonotonicRepTimestamps(let url, let atIndex, let previous, let current) {
            #expect(url == sidecar)
            #expect(atIndex == 2)
            #expect(previous == 2.0)
            #expect(current == 1.9)
        } catch {
            Issue.record("expected .nonMonotonicRepTimestamps, got \(error)")
        }
    }

    @Test("a plate diameter on a bodyweight exercise throws .plateDiameterOnBodyweight")
    func plateDiameterOnBodyweightThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(equipment: .bodyweight, plateDiameterMm: 450)
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .plateDiameterOnBodyweight")
        } catch FixtureLoadError.plateDiameterOnBodyweight(let url, let mm) {
            #expect(url == sidecar)
            #expect(mm == 450)
        } catch {
            Issue.record("expected .plateDiameterOnBodyweight, got \(error)")
        }
    }

    @Test("a non-positive plate diameter throws .invalidPlateDiameter")
    func invalidPlateDiameterThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(equipment: .barbell, plateDiameterMm: 0)
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .invalidPlateDiameter")
        } catch FixtureLoadError.invalidPlateDiameter(let url, let mm) {
            #expect(url == sidecar)
            #expect(mm == 0)
        } catch {
            Issue.record("expected .invalidPlateDiameter, got \(error)")
        }
    }

    @Test("a non-positive reference velocity throws .invalidReferenceVelocity")
    func invalidReferenceVelocityThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(
            trueRepCount: 3,
            referenceMeanConcentricVelocity: [0.5, -0.1, 0.4]
        )
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .invalidReferenceVelocity")
        } catch FixtureLoadError.invalidReferenceVelocity(let url, let atIndex, let value) {
            #expect(url == sidecar)
            #expect(atIndex == 1)
            #expect(value == -0.1)
        } catch {
            Issue.record("expected .invalidReferenceVelocity, got \(error)")
        }
    }

    @Test("a set boundary with endTime not after startTime throws .invalidSetBoundary")
    func invalidSetBoundaryThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(
            trueSetBoundaries: [Fixture.SetBoundary(startTime: 5, endTime: 5)]
        )
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .invalidSetBoundary")
        } catch FixtureLoadError.invalidSetBoundary(let url, let atIndex, let start, let end) {
            #expect(url == sidecar)
            #expect(atIndex == 0)
            #expect(start == 5)
            #expect(end == 5)
        } catch {
            Issue.record("expected .invalidSetBoundary, got \(error)")
        }
    }

    @Test("overlapping set boundaries throw .overlappingSetBoundaries")
    func overlappingSetBoundariesThrows() {
        let sidecar = URL(fileURLWithPath: "/fixtures/bad.json")
        let fixture = validFixture(
            trueSetBoundaries: [
                Fixture.SetBoundary(startTime: 0, endTime: 10),
                Fixture.SetBoundary(startTime: 9, endTime: 20),
            ]
        )
        do {
            try FixtureLoader.validate(fixture, sidecar: sidecar)
            Issue.record("expected .overlappingSetBoundaries")
        } catch FixtureLoadError.overlappingSetBoundaries(let url, let atIndex) {
            #expect(url == sidecar)
            #expect(atIndex == 1)
        } catch {
            Issue.record("expected .overlappingSetBoundaries, got \(error)")
        }
    }

    @Test("a valid fixture passes validation without throwing")
    func validFixturePasses() throws {
        try FixtureLoader.validate(validFixture(), sidecar: URL(fileURLWithPath: "/fixtures/ok.json"))
    }

    // MARK: - Malformed sidecar: useful error, never a crash

    @Test("malformed JSON throws .malformedJSON naming the sidecar, not a crash")
    func malformedJSONThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecarURL = dir.appendingPathComponent("broken.json")
        let videoURL = dir.appendingPathComponent("broken.mov")
        try write("{ not valid json ", to: sidecarURL)
        try touch(videoURL)

        do {
            _ = try FixtureLoader.loadFixture(sidecarURL: sidecarURL, videoURL: videoURL)
            Issue.record("expected .malformedJSON")
        } catch FixtureLoadError.malformedJSON(let url, _) {
            #expect(url == sidecarURL)
        } catch {
            Issue.record("expected .malformedJSON, got \(error)")
        }
    }

    @Test("JSON that doesn't match the schema throws .malformedJSON, not a crash")
    func schemaMismatchThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sidecarURL = dir.appendingPathComponent("wrong-shape.json")
        let videoURL = dir.appendingPathComponent("wrong-shape.mov")
        try write(#"{"exerciseId": "x", "equipment": "unicycle"}"#, to: sidecarURL)
        try touch(videoURL)

        do {
            _ = try FixtureLoader.loadFixture(sidecarURL: sidecarURL, videoURL: videoURL)
            Issue.record("expected .malformedJSON")
        } catch FixtureLoadError.malformedJSON(let url, _) {
            #expect(url == sidecarURL)
        } catch {
            Issue.record("expected .malformedJSON, got \(error)")
        }
    }

    // MARK: - Directory walking

    @Test("a .mov with no sidecar reports .missingSidecar and a .json with no video reports .missingVideo")
    func directoryPairingMismatchesReported() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try touch(dir.appendingPathComponent("orphan_video.mov"))
        try write(try encode(validFixture()), to: dir.appendingPathComponent("orphan_sidecar.json"))

        let result = try FixtureLoader.load(directory: dir)

        #expect(result.fixtures.isEmpty)
        #expect(result.issues.count == 2)
        #expect(
            result.issues.contains {
                if case .missingSidecar(let video) = $0 { video.lastPathComponent == "orphan_video.mov" } else {
                    false
                }
            }
        )
        #expect(
            result.issues.contains {
                if case .missingVideo(let sidecar) = $0 {
                    sidecar.lastPathComponent == "orphan_sidecar.json"
                } else {
                    false
                }
            }
        )
    }

    @Test("a directory with one bad fixture among good ones still returns the good ones")
    func oneBadFixtureAmongGoodOnesIsSkippedNotFatal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two good fixtures.
        try write(try encode(validFixture(trueRepCount: 5)), to: dir.appendingPathComponent("good_one.json"))
        try touch(dir.appendingPathComponent("good_one.mov"))
        try write(try encode(validFixture(trueRepCount: 3)), to: dir.appendingPathComponent("good_two.json"))
        try touch(dir.appendingPathComponent("good_two.mov"))

        // One bad fixture: negative rep count.
        try write(try encode(validFixture(trueRepCount: -1)), to: dir.appendingPathComponent("bad_three.json"))
        try touch(dir.appendingPathComponent("bad_three.mov"))

        let result = try FixtureLoader.load(directory: dir)

        #expect(result.fixtures.count == 2)
        #expect(result.issues.count == 1)
        let names = Set(result.fixtures.map(\.sidecarURL.lastPathComponent))
        #expect(names == ["good_one.json", "good_two.json"])

        guard case .negativeRepCount(let url, let value) = result.issues[0] else {
            Issue.record("expected the single issue to be .negativeRepCount, got \(result.issues[0])")
            return
        }
        #expect(url.lastPathComponent == "bad_three.json")
        #expect(value == -1)
    }

    @Test("loading a directory that doesn't exist throws .directoryNotFound")
    func missingDirectoryThrows() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-tests-does-not-exist-\(UUID().uuidString)")
        do {
            _ = try FixtureLoader.load(directory: dir)
            Issue.record("expected .directoryNotFound")
        } catch FixtureLoaderError.directoryNotFound(let url) {
            #expect(url == dir)
        } catch {
            Issue.record("expected .directoryNotFound, got \(error)")
        }
    }
}
