import Foundation
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
func digest(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func message(version: String, sha256: String, size: Int64) -> Data {
    Data("HaBar update v1\n\(version)\n\(sha256)\n\(size)\nio.github.habar.menubar\n".utf8)
}
let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.count == 2 && args[0] == "--generate" {
        let url = URL(fileURLWithPath: args[1])
        guard !FileManager.default.fileExists(atPath: url.path) else { fail("Refusing to overwrite an existing private key") }
        let key = Curve25519.Signing.PrivateKey()
        guard FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions:0o600]) else { fail("Couldn't save private key") }
        print(key.publicKey.rawRepresentation.base64EncodedString())
        exit(0)
    }
    guard args.count == 4, ["--sign", "--verify"].contains(args[0]) else { fail("Usage: sign_update.swift --sign|--verify <zip> <version> <public-key-base64> | --generate <private-key-file>") }
    let file = URL(fileURLWithPath: args[1]); let version = args[2]
    guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
          let publicData = Data(base64Encoded: args[3]) else { fail("Invalid version or public key") }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    let data = message(version: version, sha256: try digest(file), size: size)
    let signatureURL = URL(fileURLWithPath: file.path + ".sig")
    if args[0] == "--sign" {
        guard let encoded = ProcessInfo.processInfo.environment["HABAR_UPDATE_PRIVATE_KEY"], let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("HABAR_UPDATE_PRIVATE_KEY is missing") }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        guard privateKey.publicKey.rawRepresentation == publicData else { fail("Private key does not match the public key embedded in the app") }
        let signature = try privateKey.signature(for: data)
        try Data(signature.base64EncodedString().utf8).write(to: signatureURL, options: .atomic)
    }
    guard let signature = Data(base64Encoded: try String(contentsOf: signatureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), publicKey.isValidSignature(signature, for: data) else { fail("Update signature verification failed") }
    print("Verified Ed25519 signature for HaBar \(version)")
} catch { fail("Signing/verification failed: \(error.localizedDescription)") }
