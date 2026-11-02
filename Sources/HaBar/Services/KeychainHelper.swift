import Foundation
import Security

public enum KeychainHelper {
    private static let service = "io.github.habar.menubar"
    private static let tokenAccount = "ha_long_lived_token"
    private static let serverURLKey = "habar_ha_server_url"
    private static let tokenDefaultsKey = "habar_ha_token_backup"
    private static let useDemoModeKey = "habar_ha_demo_mode"

    /// Unit tests point the config file at a temporary directory and skip Keychain / UserDefaults.
    public static var configDirectoryOverride: URL?
    public static var isIsolatedForTesting = false

    private static var configFileURL: URL {
        let directory = configDirectoryOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/habar")
        return directory.appendingPathComponent("config.json")
    }

    // MARK: - Server URL

    public static var serverURLString: String {
        get {
            if let fileCfg = readConfigFile(),
               let url = fileCfg["server_url"] as? String,
               !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return url.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let saved = isIsolatedForTesting ? "" : (UserDefaults.standard.string(forKey: serverURLKey) ?? "")
            return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "http://homeassistant.local:8123"
                : saved
        }
    }

    // MARK: - Optional advanced settings (config.json only)

    public static var fallbackURLString: String? {
        guard let fileCfg = readConfigFile(),
              let fallback = fileCfg["fallback_url"] as? String,
              !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var ignoredEntitySuffixes: [String] {
        if let fileCfg = readConfigFile(),
           let suffixes = fileCfg["ignored_entity_suffixes"] as? [String],
           !suffixes.isEmpty {
            return suffixes
        }
        return []
    }

    public static var stripScenePrefixes: [String] {
        if let fileCfg = readConfigFile(),
           let prefixes = fileCfg["strip_scene_prefixes"] as? [String] {
            return prefixes
        }
        return []
    }

    /// Optional user-defined momentary scripts (e.g. IR remote commands) shown as buttons.
    /// ```json
    /// "script_commands": [
    ///   { "entity_id": "script.ac_on", "name": "AC on", "icon": "snowflake", "room": "office" }
    /// ]
    /// ```
    public static let defaultScriptCommands: [ScriptCommand] = []

    public static var scriptCommands: [ScriptCommand] {
        if let fileCfg = readConfigFile(),
           let raw = fileCfg["script_commands"] as? [[String: Any]] {
            return raw.compactMap { entry in
                guard let entityId = entry["entity_id"] as? String, entityId.hasPrefix("script.") else { return nil }
                return ScriptCommand(
                    entityId: entityId,
                    name: (entry["name"] as? String) ?? entityId,
                    icon: (entry["icon"] as? String) ?? "play.fill",
                    roomId: entry["room"] as? String
                )
            }
        }
        return defaultScriptCommands
    }

    public static var isDemoModePreferred: Bool {
        get {
            if isIsolatedForTesting || UserDefaults.standard.object(forKey: useDemoModeKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: useDemoModeKey)
        }
        set {
            guard !isIsolatedForTesting else { return }
            UserDefaults.standard.set(newValue, forKey: useDemoModeKey)
        }
    }

    // MARK: - Token

    public struct StorageError: LocalizedError {
        let status: OSStatus
        public var errorDescription: String? {
            L10n.t("Não foi possível acessar o Chaves do macOS", "Couldn't access macOS Keychain") + " (\(status))."
        }
    }

    private static var testTokens: [String: String] = [:]
    public static var lastError: String?
    static var testingWriteError: OSStatus?

    private static func account(for server: String) -> String {
        "ha_token:" + (HomeAssistantURL.normalized(server) ?? server)
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func saveConnection(url: String, token: String) throws {
        guard let normalized = HomeAssistantURL.normalized(url) else { throw HAAPIError.invalidURL }
        try saveToken(token, server: normalized)
        try writeConfigFile(serverURL: normalized)
        if !isIsolatedForTesting {
            UserDefaults.standard.set(normalized, forKey: serverURLKey)
            UserDefaults.standard.removeObject(forKey: tokenDefaultsKey)
            SecItemDelete(query(account: tokenAccount) as CFDictionary)
        }
        lastError = nil
    }

    public static func saveToken(_ token: String, server: String? = nil) throws {
        let key = account(for: server ?? serverURLString)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIsolatedForTesting {
            if let status = testingWriteError { throw StorageError(status: status) }
            testTokens[key] = trimmed; return
        }
        let base = query(account: key)
        if trimmed.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }

    private static func readToken(account: String) throws -> String? {
        if isIsolatedForTesting { return testTokens[account] }
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw StorageError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public static func loadToken() -> String {
        let server = serverURLString
        do {
            let existing = try readToken(account: account(for: server))
            let legacy = try (readConfigFile()?["token"] as? String)
                ?? (isIsolatedForTesting ? nil : UserDefaults.standard.string(forKey: tokenDefaultsKey))
                ?? (try readToken(account: tokenAccount))
            if let token = existing ?? legacy, !token.isEmpty {
                // Remove plaintext copies only after the secure write succeeds.
                if legacy != nil { try saveConnection(url: server, token: token) }
                lastError = nil
                return token
            }
            lastError = nil
        } catch { lastError = error.localizedDescription }
        return ""
    }

    public static func resetTestingStorage() { testTokens = [:]; lastError = nil; testingWriteError = nil }

    // MARK: - Config file

    private static func readConfigFile() -> [String: Any]? {
        if isIsolatedForTesting && configDirectoryOverride == nil { return nil }
        guard let data = try? Data(contentsOf: configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeConfigFile(serverURL: String) throws {
        if isIsolatedForTesting && configDirectoryOverride == nil { return }
        let dir = configFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var payload = readConfigFile() ?? [:]
        payload["server_url"] = serverURL
        payload.removeValue(forKey: "token")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
    }
}
