import Foundation
import CryptoKit

/// The private counterpart exists only in the release signing secret, never in the app.
public enum UpdateTrust {
    public static let publicKeyBase64 = "Yq9eTh89lKK7XOfG7dpfN+O0wny7tfLiVpLRsiBFItA="
    public static var isConfigured: Bool { Data(base64Encoded: publicKeyBase64)?.count == 32 }

    static func message(version: String, sha256: String?, size: Int64?) throws -> Data {
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              let sha256, sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              let size, size > 0 else { throw invalidSignature }
        return Data("HaBar update v1\n\(version)\n\(sha256.lowercased())\n\(size)\nio.github.habar.menubar\n".utf8)
    }

    static func verify(signature encoded: Data, version: String, sha256: String?, size: Int64?, publicKey: Data? = nil) throws {
        guard encoded.count <= 1024, let text = String(data: encoded, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64,
              let rawKey = publicKey ?? Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              key.isValidSignature(signature, for: try message(version: version, sha256: sha256, size: size)) else { throw invalidSignature }
    }
    static var invalidSignature: AppUpdaterError {
        .downloadFailed(L10n.t("Assinatura de atualização ausente ou inválida.", "Missing or invalid update signature."))
    }
}
