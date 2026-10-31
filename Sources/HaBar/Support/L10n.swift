import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case pt
    case en

    public var title: String {
        switch self {
        case .system: return L10n.t("Automático (Sistema)", "Automatic (System)")
        case .pt: return "Português (Brasil)"
        case .en: return "English"
        }
    }
}

/// Minimal bilingual (pt-BR / English) string helper.
///
/// The app is a SwiftPM executable assembled into a bundle by `scripts/build_app.sh`,
/// so string catalogs (which need Xcode's resource pipeline) are intentionally avoided.
public enum L10n {
    /// Overrides the system language (used by preferences or unit tests). Accepts "pt", "en" or nil.
    public static var forcedLanguage: String?

    public static var isPortuguese: Bool {
        let language = forcedLanguage ?? Locale.preferredLanguages.first ?? "en"
        return language.lowercased().hasPrefix("pt")
    }

    public static func t(_ portuguese: String, _ english: String) -> String {
        isPortuguese ? portuguese : english
    }
}
