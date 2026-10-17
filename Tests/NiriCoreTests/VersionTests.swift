import Testing
@testable import NiriCore

@Test func newerVersion() {
    #expect(Version.isNewer("0.10.0", than: "0.9.1"))
    #expect(Version.isNewer("1.0.0", than: "0.99.99"))
    #expect(Version.isNewer("0.1.1", than: "0.1"))
    #expect(!Version.isNewer("0.1.0", than: "0.1"))
    #expect(!Version.isNewer("0.1.0", than: "0.1.0"))
    #expect(!Version.isNewer("0.9.9", than: "0.10.0"))
}
