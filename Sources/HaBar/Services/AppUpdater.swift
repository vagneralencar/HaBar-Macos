import Foundation
import AppKit

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

public final class AppUpdater: @unchecked Sendable {
    public static let shared = AppUpdater()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Downloads the release zip with streaming byte progress and unzips it to a staged location.
    public func downloadAndStageUpdate(
        release: ReleaseInfo,
        progressHandler: (@Sendable (Double, Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        guard let downloadURL = release.downloadURL else {
            throw AppUpdaterError.noDownloadURL
        }

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppUpdaterError.downloadFailed("HTTP \(status)")
        }

        let totalBytes = response.expectedContentLength
        var data = Data()
        if totalBytes > 0 {
            data.reserveCapacity(Int(totalBytes))
        }

        var lastReport = Date()
        for try await byte in asyncBytes {
            data.append(byte)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.1 || data.count == totalBytes {
                let progress = totalBytes > 0 ? Double(data.count) / Double(totalBytes) : 0.0
                progressHandler?(min(1.0, max(0.0, progress)), Int64(data.count), totalBytes)
                lastReport = now
            }
        }

        // Final 100% callback
        progressHandler?(1.0, Int64(data.count), totalBytes > 0 ? totalBytes : Int64(data.count))

        // Create isolated temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.github.habar.updater")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipURL = tempDir.appendingPathComponent("HaBar-\(release.version).zip")
        try data.write(to: zipURL, options: .atomic)

        let stagingDir = tempDir.appendingPathComponent("Staged")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Unarchive with /usr/bin/ditto (preserves symlinks and macOS metadata)
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = ["-xk", zipURL.path, stagingDir.path]

        let dittoErrorPipe = Pipe()
        dittoProcess.standardError = dittoErrorPipe

        do {
            try dittoProcess.run()
            dittoProcess.waitUntilExit()
            if dittoProcess.terminationStatus != 0 {
                let errData = dittoErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "ditto exited with \(dittoProcess.terminationStatus)"
                throw AppUpdaterError.unarchiveFailed(errMsg)
            }
        } catch let err as AppUpdaterError {
            throw err
        } catch {
            throw AppUpdaterError.unarchiveFailed(error.localizedDescription)
        }

        // Locate HaBar.app inside stagingDir
        let stagedAppURL = stagingDir.appendingPathComponent("HaBar.app")
        guard FileManager.default.fileExists(atPath: stagedAppURL.path) else {
            throw AppUpdaterError.appBundleNotFound
        }

        // Validate bundle identifier
        if let bundle = Bundle(url: stagedAppURL),
           let bundleId = bundle.bundleIdentifier,
           bundleId != "io.github.habar.menubar" {
            throw AppUpdaterError.invalidBundleIdentifier(bundleId)
        }

        // Strip com.apple.quarantine attribute so Gatekeeper allows immediate launch
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-dr", "com.apple.quarantine", stagedAppURL.path]
        try? xattrProcess.run()
        xattrProcess.waitUntilExit()

        return stagedAppURL
    }

    /// Replaces the target bundle with the staged app and relaunches it seamlessly.
    public func installAndRelaunch(
        stagedAppURL: URL,
        targetBundleURL: URL = Bundle.main.bundleURL,
        terminator: (@Sendable () -> Void)? = nil
    ) throws {
        let parentDir = targetBundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw AppUpdaterError.noWritePermission(targetBundleURL.path)
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("habar-relaunch-\(UUID().uuidString).sh")

        let currentPID = ProcessInfo.processInfo.processIdentifier

        let scriptContent = """
        #!/bin/bash
        PID="\(currentPID)"
        STAGED="\(stagedAppURL.path)"
        TARGET="\(targetBundleURL.path)"

        # Wait for the host process to terminate
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.15
        done

        # Replace the target application bundle
        rm -rf "$TARGET"
        mv "$STAGED" "$TARGET"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

        # Reopen the updated app
        /usr/bin/open "$TARGET"

        # Self-destruct relaunch script
        rm -f "$0"
        """

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Make executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Launch detached process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        do {
            try process.run()
        } catch {
            throw AppUpdaterError.relaunchScriptFailed(error.localizedDescription)
        }

        // Terminate caller
        if let terminator {
            terminator()
        } else {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
