import Testing
@testable import GitCoworkCore

@Suite struct SemanticVersionTests {
    @Test func parses() {
        #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("0.10")?.description == "0.10.0")
        #expect(SemanticVersion("2.0.0-beta.2")?.prerelease == "beta.2")
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1.x.3") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
    }

    @Test func orders() {
        func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }
        #expect(v("0.9.2") < v("0.10.0"))
        #expect(v("0.1.0") < v("0.1.1"))
        #expect(v("1.0.0-beta.2") < v("1.0.0-beta.10"))
        #expect(v("1.0.0-beta") < v("1.0.0"))
        #expect(!(v("1.0.0") < v("1.0.0-rc.1")))
        #expect(v("v1.2.3") == v("1.2.3"))
    }
}
