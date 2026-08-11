import Testing

@testable import timmethod_eval

@Suite("EvalCommand argument parsing")
struct EvalCommandTests {
    @Test("accepts the full flag set from the SPEC §15 example")
    func parsesFullFlagSet() throws {
        let command = try EvalCommand.parse([
            "--fixtures", "./fixtures",
            "--provider", "apple-vision-3d",
            "--report", "./out/report.json",
        ])
        #expect(command.fixtures == "./fixtures")
        #expect(command.provider == .appleVision3D)
        #expect(command.report == "./out/report.json")
        #expect(command.filter == nil)
        #expect(command.verbose == false)
    }

    @Test("accepts --filter and --verbose")
    func parsesOptionalFlags() throws {
        let command = try EvalCommand.parse([
            "--fixtures", "./fixtures",
            "--report", "./out/report.json",
            "--filter", "squat",
            "--verbose",
        ])
        #expect(command.filter == "squat")
        #expect(command.verbose == true)
        #expect(command.provider == .appleVision3D)
    }

    @Test("rejects a provider outside apple-vision-3d / mediapipe")
    func rejectsUnknownProvider() {
        #expect(throws: (any Error).self) {
            try EvalCommand.parse([
                "--fixtures", "./fixtures",
                "--provider", "openpose",
                "--report", "./out/report.json",
            ])
        }
    }

    @Test("rejects a missing required --fixtures")
    func rejectsMissingFixtures() {
        #expect(throws: (any Error).self) {
            try EvalCommand.parse([
                "--report", "./out/report.json",
            ])
        }
    }
}
