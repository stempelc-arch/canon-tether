import XCTest
@testable import CanonTetherCore

final class SemanticVersionTests: XCTestCase {
    func testNewerVersionsDetected() {
        XCTAssertTrue(SemanticVersion.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(SemanticVersion.isNewer("v1.1", than: "1.0"))
        XCTAssertTrue(SemanticVersion.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(SemanticVersion.isNewer("2.0", than: "1.9.9"))
    }

    /// Component-wise numeric comparison, not string comparison — "1.10" beats "1.9".
    func testDoubleDigitComponents() {
        XCTAssertTrue(SemanticVersion.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(SemanticVersion.isNewer("1.9", than: "1.10"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(SemanticVersion.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(SemanticVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer("1.0", than: "1.1"))
    }

    /// A tag we can't parse must never prompt the user to "update" to it.
    func testUnparseableTagsNeverPrompt() {
        XCTAssertFalse(SemanticVersion.isNewer("nightly", than: "1.0"))
        XCTAssertFalse(SemanticVersion.isNewer("", than: "1.0"))
        XCTAssertFalse(SemanticVersion.isNewer("1.1", than: "unknown"))
    }

    /// Development builds report a sentinel version so they can't be told they're out of date.
    func testDevelopmentSentinelNeverOutdated() {
        XCTAssertFalse(SemanticVersion.isNewer("1.1", than: "999.0"))
    }

    func testPrereleaseSuffixIgnored() {
        XCTAssertTrue(SemanticVersion.isNewer("1.2.3-beta", than: "1.2.2"))
        XCTAssertEqual(SemanticVersion.components("1.2.3-beta"), [1, 2, 3])
    }
}
