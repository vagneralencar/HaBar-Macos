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

    func testParseReleaseJSONWithAssets() {
        let jsonString = """
        {
            "tag_name": "v1.6.0",
            "html_url": "https://github.com/vagneralencar/HaBar-Macos/releases/tag/v1.6.0",
            "body": "### Release notes for v1.6.0\\n- Feature A\\n- Feature B",
            "assets": [
                {
                    "name": "HaBar.zip",
                    "browser_download_url": "https://github.com/vagneralencar/HaBar-Macos/releases/download/v1.6.0/HaBar.zip",
                    "size": 2768068,
                    "digest": "sha256:abc123def456"
                }
            ]
        }
        """
        let data = Data(jsonString.utf8)
        let release = UpdateChecker.parseRelease(from: data)

        XCTAssertNotNil(release)
        XCTAssertEqual(release?.version, "1.6.0")
        XCTAssertEqual(release?.url.absoluteString, "https://github.com/vagneralencar/HaBar-Macos/releases/tag/v1.6.0")
        XCTAssertEqual(release?.downloadURL?.absoluteString, "https://github.com/vagneralencar/HaBar-Macos/releases/download/v1.6.0/HaBar.zip")
        XCTAssertEqual(release?.assetSize, 2768068)
        XCTAssertEqual(release?.sha256, "abc123def456")
        XCTAssertTrue(release?.body.contains("Feature A") == true)
        XCTAssertNotNil(release?.formattedSize)
    }

    func testParseReleaseJSONWithoutAssets() {
        let jsonString = """
        {
            "tag_name": "v1.5.0",
            "html_url": "https://github.com/vagneralencar/HaBar-Macos/releases/tag/v1.5.0",
            "body": "No assets"
        }
        """
        let data = Data(jsonString.utf8)
        let release = UpdateChecker.parseRelease(from: data)

        XCTAssertNotNil(release)
        XCTAssertEqual(release?.version, "1.5.0")
        XCTAssertNil(release?.downloadURL)
        XCTAssertNil(release?.assetSize)
        XCTAssertNil(release?.sha256)
        XCTAssertNil(release?.formattedSize)
    }
}
