import Testing

@testable import TimMethodCore

@Suite("TimMethodCore")
struct TimMethodCoreTests {
    @Test("version is a non-empty semantic version string")
    func versionIsWellFormed() {
        let components = TimMethodCore.version.split(separator: ".")
        #expect(components.count == 3)
        #expect(components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }
}
