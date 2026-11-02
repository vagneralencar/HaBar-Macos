import Foundation
import AppKit
import CryptoKit
import Security

public enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading(progress: Double, bytesReceived: Int64, totalBytes: Int64)
    case readyToInstall(ReleaseInfo, stagedAppURL: URL)
    case installing
    case failed(String)
}

public enum AppUpdaterError: LocalizedError, Sendable {
    case noDownloadURL
    case downloadFailed(String)
    case unarchiveFailed(String)
    case appBundleNotFound
    case invalidBundleIdentifier(String)
    case noWritePermission(String)
    case relaunchScriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            return L10n.t("Nenhum arquivo zip encontrado no release.", "No zip file found in release assets.")
        case .downloadFailed(let reason):
            return L10n.t("Falha ao baixar atualização: \(reason)", "Failed to download update: \(reason)")
        case .unarchiveFailed(let reason):
            return L10n.t("Falha ao descompactar atualização: \(reason)", "Failed to unpack update: \(reason)")
        case .appBundleNotFound:
            return L10n.t("Aplicativo HaBar.app não encontrado no arquivo baixado.", "HaBar.app not found in downloaded archive.")
        case .invalidBundleIdentifier(let id):
            return L10n.t("Identificador de pacote inválido: \(id)", "Invalid bundle identifier: \(id)")
        case .noWritePermission(let path):
            return L10n.t("Sem permissão para substituir o app em \(path).", "No permission to replace app at \(path).")
        case .relaunchScriptFailed(let reason):
            return L10n.t("Falha ao preparar reinicialização: \(reason)", "Failed to stage relaunch: \(reason)")
        }
    }
}


private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (@Sendable (Double, Int64, Int64) -> Void)?
    let limit: Int64
    init(limit: Int64, report: (@Sendable (Double, Int64, Int64) -> Void)?) { self.limit = limit; self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else { downloadTask.cancel(); return }
        report?(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0, totalBytesWritten, totalBytesExpectedToWrite)
    }
}

public final class AppUpdater: @unchecked Sendable {
    public static let shared = AppUpdater()
    private let session: URLSession
    private static let maxDownloadBytes: Int64 = 200 * 1024 * 1024
    public init(session: URLSession = .shared) { self.session = session }

    private let verificationLock = NSLock()
    private var verifiedBundles: [URL: (fingerprint: Data, version: String)] = [:]

    public static var supportsSecureUpdates: Bool { UpdateTrust.isConfigured }
    public static func signingTeam(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func verifyDigest(file: URL, expected: String?) throws {
        guard let expected, expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw AppUpdaterError.downloadFailed(L10n.t("Checksum SHA-256 ausente ou inválido.", "Missing or invalid SHA-256 checksum."))
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw AppUpdaterError.downloadFailed(L10n.t("O checksum do pacote não corresponde.", "Package checksum mismatch."))
        }
    }

    public static func validateBundle(at url: URL, expectedTeam: String? = nil, version: String? = nil) throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "io.github.habar.menubar",
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path),
              executable.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/") else {
            throw AppUpdaterError.invalidBundleIdentifier("missing or invalid bundle")
        }
        if let version, bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String != version {
            throw AppUpdaterError.downloadFailed(L10n.t("Versão do pacote inesperada.", "Unexpected package version."))
        }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard !parts.isEmpty, ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)) else {
                throw AppUpdaterError.downloadFailed(L10n.t("Esta atualização exige uma versão mais recente do macOS.", "This update requires a newer macOS version."))
            }
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        if let expectedTeam {
            guard expectedTeam.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw UpdateTrust.invalidSignature }
            let text = "anchor apple generic and identifier \"io.github.habar.menubar\" and certificate leaf[subject.OU] = \"\(expectedTeam)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw UpdateTrust.invalidSignature }
        }
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw AppUpdaterError.downloadFailed(L10n.t("Assinatura do aplicativo inválida ou de outro desenvolvedor.", "Invalid application signature or a different developer."))
        }
    }

    public func downloadAndStageUpdate(release: ReleaseInfo, progressHandler: (@Sendable (Double, Int64, Int64) -> Void)? = nil) async throws -> URL {
        let team = Self.signingTeam(at: Bundle.main.bundleURL)
        _ = try UpdateTrust.message(version: release.version, sha256: release.sha256, size: release.assetSize)
        guard AppInfo.version == "dev" || UpdateChecker.isNewer(release.version, than: AppInfo.version) else {
            throw AppUpdaterError.downloadFailed(L10n.t("A versão não é mais recente que a instalada.", "The version is not newer than the installed app."))
        }
        let prefix = "https://github.com/\(AppInfo.repository)/releases/download/v\(release.version)/HaBar.zip"
        guard let url = release.downloadURL, url.absoluteString == prefix,
              let signatureURL = release.signatureURL, signatureURL.absoluteString == prefix + ".sig",
              let size = release.assetSize, size > 0, size <= Self.maxDownloadBytes else { throw AppUpdaterError.noDownloadURL }
        var signatureRequest = URLRequest(url: signatureURL)
        signatureRequest.timeoutInterval = 20
        let (signatureFile, signatureResponse) = try await session.download(for: signatureRequest, delegate: DownloadProgress(limit: 1024, report: nil))
        defer { try? FileManager.default.removeItem(at: signatureFile) }
        guard (signatureResponse as? HTTPURLResponse)?.statusCode == 200,
              (try signatureFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 else { throw UpdateTrust.invalidSignature }
        let signature = try Data(contentsOf: signatureFile)
        try UpdateTrust.verify(signature: signature, version: release.version, sha256: release.sha256, size: size)
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let progress = DownloadProgress(limit: Self.maxDownloadBytes, report: progressHandler)
        let (download, response) = try await session.download(for: request, delegate: progress)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppUpdaterError.downloadFailed("HTTP") }
        let actualSize = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard actualSize == size, actualSize <= Self.maxDownloadBytes else { throw AppUpdaterError.downloadFailed("Unexpected archive size") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("habar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: root) } }
        let zip = root.appendingPathComponent("HaBar.zip")
        try FileManager.default.moveItem(at: download, to: zip)
        try await Task.detached { try Self.verifyDigest(file: zip, expected: release.sha256) }.value
        try Task.checkCancellation()
        let app = try await Task.detached { () throws -> URL in
            let metadata = try Self.run("/usr/bin/zipinfo", ["-l", zip.path])
            let totals = try Self.run("/usr/bin/zipinfo", ["-t", zip.path])
            let listing = try Self.run("/usr/bin/unzip", ["-Z", "-1", zip.path])
            try Self.validateArchiveListing(metadata: metadata, totals: totals, listing: listing)
            let staging = root.appendingPathComponent("Staged")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            _ = try Self.run("/usr/bin/ditto", ["-xk", zip.path, staging.path])
            let app = staging.appendingPathComponent("HaBar.app")
            try Self.validateBundle(at: app, expectedTeam: team, version: release.version)
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            guard let executable = Bundle(url: app)?.executableURL else { throw AppUpdaterError.appBundleNotFound }
            _ = try Self.run("/usr/bin/lipo", [executable.path, "-verify_arch", architecture])
            if team != nil { _ = try Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) }
            return app
        }.value
        try Task.checkCancellation()
        let fingerprint = try await Task.detached { try Self.bundleFingerprint(at: app) }.value
        rememberVerifiedBundle(app, fingerprint: fingerprint, version: release.version)
        try FileManager.default.removeItem(at: zip)
        progressHandler?(1, size, size)
        completed = true
        return app
    }

    static func validateArchiveListing(metadata: String, totals: String, listing: String) throws {
        guard !metadata.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
            throw AppUpdaterError.unarchiveFailed("Archive contains symbolic links")
        }
        let pattern = #", ([0-9]+) bytes uncompressed"#
        guard let match = totals.range(of: pattern, options: .regularExpression),
              let expandedSize = Int64(totals[match].filter(\.isNumber)), expandedSize <= 500 * 1024 * 1024 else {
            throw AppUpdaterError.unarchiveFailed("Expanded archive exceeds limit")
        }
        let entries = listing.split(separator: "\n").map(String.init)
        guard !entries.isEmpty, entries.count < 20_000,
              entries.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") && ($0.hasPrefix("HaBar.app/") || $0.hasPrefix("__MACOSX/")) }) else {
            throw AppUpdaterError.unarchiveFailed("Unsafe archive paths")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdaterError.unarchiveFailed("\(URL(fileURLWithPath: executable).lastPathComponent): \(process.terminationStatus)") }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func rememberVerifiedBundle(_ url: URL, fingerprint: Data, version: String) {
        verificationLock.lock(); defer { verificationLock.unlock() }
        verifiedBundles[url.standardizedFileURL] = (fingerprint, version)
    }
    private func verifiedBundle(_ url: URL) -> (fingerprint: Data, version: String)? {
        verificationLock.lock(); defer { verificationLock.unlock() }
        return verifiedBundles[url.standardizedFileURL]
    }

    /// Bind installation to the exact tree extracted from an authenticated archive.
    static func bundleFingerprint(at root: URL) throws -> Data {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in enumerationError = error; return false }),
              let files = enumerator.allObjects as? [URL], files.count < 20_000 else { throw UpdateTrust.invalidSignature }
        if let enumerationError { throw enumerationError }
        var hash = SHA256()
        var total: Int64 = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw UpdateTrust.invalidSignature }
            let relative = String(file.path.dropFirst(root.path.count))
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let size = values.isRegularFile == true ? (values.fileSize ?? 0) : 0
            hash.update(data: Data("\(relative)\0\(mode)\0\(values.isDirectory == true ? "D" : "F")\0\(size)\0".utf8))
            if values.isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    total += Int64(chunk.count)
                    guard total <= 500 * 1024 * 1024 else { throw UpdateTrust.invalidSignature }
                    hash.update(data: chunk)
                }
            }
        }
        return Data(hash.finalize())
    }

    /// Keep a verified sibling on the destination volume and a recoverable backup.
    public func installAndRelaunch(stagedAppURL: URL, targetBundleURL: URL = Bundle.main.bundleURL, terminator: (@Sendable () -> Void)? = nil) throws {
        guard targetBundleURL.pathExtension == "app", Bundle(url: targetBundleURL)?.bundleIdentifier == "io.github.habar.menubar",
              let verified = verifiedBundle(stagedAppURL), try Self.bundleFingerprint(at: stagedAppURL) == verified.fingerprint else { throw UpdateTrust.invalidSignature }
        let team = Self.signingTeam(at: targetBundleURL)
        try Self.validateBundle(at: stagedAppURL, expectedTeam: team, version: verified.version)
        let parent = targetBundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw AppUpdaterError.noWritePermission(parent.path) }
        let sibling = parent.appendingPathComponent(".HaBar-update-\(UUID().uuidString).app")
        let backup = parent.appendingPathComponent(".HaBar-backup-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: stagedAppURL, to: sibling)
        do {
            try Self.validateBundle(at: sibling, expectedTeam: team, version: verified.version)
            guard try Self.bundleFingerprint(at: sibling) == verified.fingerprint else { throw UpdateTrust.invalidSignature }
        }
        catch { try? FileManager.default.removeItem(at: sibling); throw error }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("habar-install-\(UUID().uuidString).sh")
        // Paths are arguments, never shell source. A failed move/open restores the previous app.
        let source = """
        #!/bin/bash
        set -eu
        PID="$1"; STAGED="$2"; TARGET="$3"; BACKUP="$4"; TEMP_ROOT="$5"
        rollback() {
            if [ -d "$BACKUP" ]; then
                if [ -d "$TARGET" ]; then /bin/mv "$TARGET" "$STAGED"; fi
                /bin/mv "$BACKUP" "$TARGET"
                /usr/bin/open "$TARGET" || true
            fi
        }
        trap rollback ERR
        for ((i=0; i<400; i++)); do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            /bin/sleep 0.15
        done
        if kill -0 "$PID" 2>/dev/null; then exit 1; fi
        /bin/mv "$TARGET" "$BACKUP"
        /bin/mv "$STAGED" "$TARGET"
        /usr/bin/open "$TARGET"
        trap - ERR
        # Retain the previous bundle for recovery; cleanup only the private staging directory.
        case "$TEMP_ROOT" in */habar-update-*) /bin/rm -rf "$TEMP_ROOT" ;; esac
        /bin/rm -f "$0"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), sibling.path, targetBundleURL.path, backup.path, stagedAppURL.deletingLastPathComponent().deletingLastPathComponent().path]
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: sibling); throw AppUpdaterError.relaunchScriptFailed(error.localizedDescription) }
        if let terminator { terminator() } else { DispatchQueue.main.async { NSApplication.shared.terminate(nil) } }
    }
}
