import Foundation

public struct AuditEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let entityId: String
    public let entityName: String
    public let action: String
    public let wasBiometric: Bool
    public var outcome: String? = nil
    public var authenticated: Bool? = nil

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        entityId: String,
        entityName: String,
        action: String,
        wasBiometric: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.entityId = entityId
        self.entityName = entityName
        self.action = action
        self.wasBiometric = wasBiometric
    }

    public var outcomeLabel: String {
        switch outcome {
        case "requested": return L10n.t("Solicitado", "Requested")
        case "accepted": return L10n.t("Aceito pelo servidor", "Accepted by server")
        case "confirmed": return L10n.t("Estado confirmado", "State confirmed")
        case "unconfirmed": return L10n.t("Sem confirmação", "Unconfirmed")
        case "demo": return L10n.t("Demonstração", "Demo")
        default: return L10n.t("Registro antigo", "Legacy entry")
        }
    }
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: timestamp)
    }
}

@MainActor
public final class AuditLogger: ObservableObject {
    public static let shared = AuditLogger()

    @Published public private(set) var entries: [AuditEntry] = []
    @Published public private(set) var persistenceError: String?
    private let maxEntries = 50
    private let logFileURL: URL
    private let ioQueue = DispatchQueue(label: "habar.audit.io", qos: .utility)

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.logFileURL = fileURL
        } else {
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("habar")
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            self.logFileURL = configDir.appendingPathComponent("audit.json")
        }
        loadEntries()
    }

    public func log(entityId: String, entityName: String, action: String, wasBiometric: Bool = false, outcome: String = "requested", authenticated: Bool = false) {
        var entry = AuditEntry(
            entityId: entityId,
            entityName: entityName,
            action: action,
            wasBiometric: wasBiometric
        )
        entry.outcome = outcome
        entry.authenticated = authenticated
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        saveEntries()
    }

    public func clear() {
        entries.removeAll()
        let url = logFileURL
        ioQueue.async { [weak self] in
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                Task { @MainActor [weak self] in self?.persistenceError = nil }
            } catch {
                Task { @MainActor [weak self] in self?.persistenceError = L10n.t("Não foi possível apagar o histórico salvo.", "Couldn't remove the saved history.") }
            }
        }
    }

    private func loadEntries() {
        guard let data = try? Data(contentsOf: logFileURL),
              let decoded = try? JSONDecoder().decode([AuditEntry].self, from: data) else {
            return
        }
        self.entries = Array(decoded.prefix(maxEntries))
    }

    private func saveEntries() {
        let snapshot = entries
        let url = logFileURL
        ioQueue.async { [weak self] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                Task { @MainActor [weak self] in self?.persistenceError = nil }
            } catch {
                Task { @MainActor [weak self] in self?.persistenceError = L10n.t("O histórico está disponível apenas nesta sessão: não foi possível salvá-lo.", "History is available only in this session: it couldn't be saved.") }
            }
        }
    }
}
