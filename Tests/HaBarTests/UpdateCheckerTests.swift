import XCTest
@testable import HaBar

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        // Standard bump
        XCTAssertTrue(UpdateChecker.isNewer("1.3.0", than: "1.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))

        // Multi-digit components
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.2", than: "1.10.0"))

        // Prefix "v" normalization
        XCTAssertTrue(UpdateChecker.isNewer("v1.4.0", than: "1.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.4.0", than: "v1.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.3.0", than: "1.3.0"))

        // Same version
        XCTAssertFalse(UpdateChecker.isNewer("1.3.0", than: "1.3.0"))

        // Dev version ignores nag
        XCTAssertFalse(UpdateChecker.isNewer("1.5.0", than: "dev"))
    }
}
