import Foundation

/// Minimal bilingual (pt-BR / English) string helper.
///
/// The app is a SwiftPM executable assembled into a bundle by `scripts/build_app.sh`,
/// so string catalogs (which need Xcode's resource pipeline) are intentionally avoided.
public enum L10n {
    /// Overrides the system language (used by unit tests). Accepts "pt" or "en".
    public static var forcedLanguage: String?

    public static var isPortuguese: Bool {
        let language = forcedLanguage ?? Locale.preferredLanguages.first ?? "en"
        return language.lowercased().hasPrefix("pt")
    }

    public static func t(_ portuguese: String, _ english: String) -> String {
        isPortuguese ? portuguese : english
    }
}
