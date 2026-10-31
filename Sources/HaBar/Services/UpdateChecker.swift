import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let downloadURL: URL?
    public let body: String
    public let assetSize: Int64?
    public let sha256: String?

    public init(
        version: String,
        url: URL,
        downloadURL: URL? = nil,
        body: String = "",
        assetSize: Int64? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.url = url
        self.downloadURL = downloadURL
        self.body = body
        self.assetSize = assetSize
        self.sha256 = sha256
    }

    public var formattedSize: String? {
        guard let assetSize, assetSize > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: assetSize)
    }
}

/// Lightweight update check against the public GitHub Releases API.
/// Only the latest public release metadata is fetched – no identifiers are sent.
public enum UpdateChecker {
    public static func fetchLatestRelease() async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        return parseRelease(from: data)
    }

    public static func parseRelease(from data: Data) -> ReleaseInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }

        let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesPage
        let body = json["body"] as? String ?? ""

        var downloadURL: URL?
        var assetSize: Int64?
        var sha256: String?

        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String, name.hasSuffix(".zip") else { continue }
                if let dlString = asset["browser_download_url"] as? String {
                    downloadURL = URL(string: dlString)
                }
                if let size = (asset["size"] as? NSNumber)?.int64Value {
                    assetSize = size
                }
                if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
                    sha256 = String(digest.dropFirst(7))
                }
                break
            }
        }

        return ReleaseInfo(
            version: normalize(tag),
            url: pageURL,
            downloadURL: downloadURL,
            body: body,
            assetSize: assetSize,
            sha256: sha256
        )
    }

    /// Compares dotted numeric versions ("1.10.0" > "1.9.2"); a leading "v" is ignored.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = components(normalize(remote))
        let localParts = components(normalize(local))
        guard !localParts.isEmpty else { return false } // "dev" builds never nag
        for index in 0..<max(remoteParts.count, localParts.count) {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let l = index < localParts.count ? localParts[index] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func normalize(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.contains(where: { $0 == nil }) ? [] : parts.compactMap { $0 }
    }
}
