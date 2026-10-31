import Foundation

public struct AuditEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let entityId: String
    public let entityName: String
    public let action: String
    public let wasBiometric: Bool

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
    private let maxEntries = 50
    private let logFileURL: URL

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

    public func log(entityId: String, entityName: String, action: String, wasBiometric: Bool = false) {
        let entry = AuditEntry(
            entityId: entityId,
            entityName: entityName,
            action: action,
            wasBiometric: wasBiometric
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        saveEntries()
    }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    private func loadEntries() {
        guard let data = try? Data(contentsOf: logFileURL),
              let decoded = try? JSONDecoder().decode([AuditEntry].self, from: data) else {
            return
        }
        self.entries = Array(decoded.prefix(maxEntries))
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: logFileURL, options: .atomic)
    }
}
