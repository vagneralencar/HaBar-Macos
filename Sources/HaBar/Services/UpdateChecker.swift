import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let url: URL
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
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }

        let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesPage
        return ReleaseInfo(version: normalize(tag), url: pageURL)
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
