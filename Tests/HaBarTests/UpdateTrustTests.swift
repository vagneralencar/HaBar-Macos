import XCTest
import CryptoKit
@testable import HaBar

final class UpdateTrustTests: XCTestCase {
    private let fixtureDigest = String(repeating: "a", count: 64)
    func testValidPublisherSignatureAndMetadataBinding() throws {
        let key = Curve25519.Signing.PrivateKey()
        let message = try UpdateTrust.message(version: "1.8.0", sha256: fixtureDigest, size: 123)
        XCTAssertEqual(String(data: message, encoding: .utf8), "HaBar update v1\n1.8.0\n\(fixtureDigest)\n123\nio.github.habar.menubar\n")
        let signature = Data(try key.signature(for: message).base64EncodedString().utf8)
        XCTAssertNoThrow(try UpdateTrust.verify(signature: signature, version: "1.8.0", sha256: fixtureDigest, size: 123, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try UpdateTrust.verify(signature: signature, version: "1.8.1", sha256: fixtureDigest, size: 123, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try UpdateTrust.verify(signature: signature, version: "1.8.0", sha256: fixtureDigest, size: 124, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try UpdateTrust.verify(signature: signature, version: "1.8.0", sha256: String(repeating: "b", count: 64), size: 123, publicKey: key.publicKey.rawRepresentation))
    }
    func testWrongKeyMissingAndMalformedSignaturesAreRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = Data(try key.signature(for: UpdateTrust.message(version: "1.8.0", sha256: fixtureDigest, size: 123)).base64EncodedString().utf8)
        XCTAssertThrowsError(try UpdateTrust.verify(signature: signature, version: "1.8.0", sha256: fixtureDigest, size: 123, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try UpdateTrust.verify(signature: Data(), version: "1.8.0", sha256: fixtureDigest, size: 123))
        XCTAssertThrowsError(try UpdateTrust.verify(signature: Data(repeating: 65, count: 1025), version: "1.8.0", sha256: fixtureDigest, size: 123))
        XCTAssertThrowsError(try UpdateTrust.message(version: "1.8.0\nother", sha256: fixtureDigest, size: 123))
        XCTAssertThrowsError(try UpdateTrust.message(version: "1.8.0", sha256: nil, size: 123))
    }
    func testStagedTreeFingerprintDetectsModifiedFilesAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("executable")
        try Data("original".utf8).write(to: file)
        let original = try AppUpdater.bundleFingerprint(at: root)
        XCTAssertEqual(try AppUpdater.bundleFingerprint(at: root), original)
        try Data("modified".utf8).write(to: file)
        XCTAssertNotEqual(try AppUpdater.bundleFingerprint(at: root), original)
        let modified = try AppUpdater.bundleFingerprint(at: root)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:file.path)
        XCTAssertNotEqual(try AppUpdater.bundleFingerprint(at: root), modified)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"), withDestinationURL:file)
        XCTAssertThrowsError(try AppUpdater.bundleFingerprint(at: root))
    }
    func testUnverifiedBundleCannotBeInstalled() {
        XCTAssertThrowsError(try AppUpdater().installAndRelaunch(stagedAppURL: URL(fileURLWithPath: "/tmp/unverified.app"), targetBundleURL: URL(fileURLWithPath: "/tmp/target.app"), terminator: { XCTFail("Must not terminate for an unverified bundle") }))
    }
    func testReleaseParserFindsSignatureAfterArchiveAsset() throws {
        let json = #"{"tag_name":"v1.8.0","assets":[{"name":"HaBar.zip","size":123},{"name":"HaBar.zip.sig","browser_download_url":"https://github.com/vagneralencar/HaBar-Macos/releases/download/v1.8.0/HaBar.zip.sig"}]}"#
        let release = try XCTUnwrap(UpdateChecker.parseRelease(from:Data(json.utf8)))
        XCTAssertEqual(release.signatureURL?.lastPathComponent, "HaBar.zip.sig")
        XCTAssertEqual(release.assetSize, 123)
    }
}
