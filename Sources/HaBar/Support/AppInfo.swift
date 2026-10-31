import Foundation

public enum AppInfo {
    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    public static let repository = "vagneralencar/HaBar-Macos"
    public static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
}
