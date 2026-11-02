import Foundation

/// Serializes all writes so a later power-off cannot be overtaken by an older dimmer request.
/// Debounced light attributes merge; power actions supersede queued attributes for that entity.
@MainActor final class CommandCoordinator {
    struct Command {
        let id: UUID
        let entityId: String
        let domain: String
        let service: String
        var payload: [String: Any]
        let authenticated: Bool
    }
    var execute: ((Command) async -> Void)?
    private var delayed: [String: Command] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var queue: [Command] = []
    private var worker: Task<Void, Never>?
    private var generation = 0

    @discardableResult func submit(entityId: String, domain: String, service: String, payload: [String: Any], debounce: Bool = false, authenticated: Bool = false) -> UUID {
        var merged = payload
        if debounce, service == "turn_on", let previous = delayed[entityId], previous.service == service {
            merged = previous.payload.merging(payload, uniquingKeysWith: { _, new in new })
            if payload["rgb_color"] != nil { merged.removeValue(forKey: "color_temp_kelvin") }
            if payload["color_temp_kelvin"] != nil { merged.removeValue(forKey: "rgb_color") }
        }
        timers.removeValue(forKey: entityId)?.cancel()
        delayed.removeValue(forKey: entityId)
        // Commands already sent aren't retried or cancelled: their result is awaited first.
        if ["turn_off", "lock", "close_cover"].contains(service) {
            queue.removeAll { $0.entityId == entityId }
        }
        let command = Command(id: UUID(), entityId: entityId, domain: domain, service: service, payload: merged, authenticated: authenticated)
        if debounce {
            delayed[entityId] = command
            timers[entityId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self, let next = self.delayed.removeValue(forKey: entityId) else { return }
                self.timers.removeValue(forKey: entityId)
                self.enqueue(next)
            }
        } else { enqueue(command) }
        return command.id
    }

    private func enqueue(_ command: Command) {
        queue.append(command)
        guard worker == nil else { return }
        let epoch = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty, !Task.isCancelled, epoch == self.generation {
                let next = self.queue.removeFirst()
                await self.execute?(next)
            }
            if epoch == self.generation { self.worker = nil }
        }
    }

    func reset() {
        generation += 1
        timers.values.forEach { $0.cancel() }; timers.removeAll(); delayed.removeAll(); queue.removeAll()
        worker?.cancel(); worker = nil
    }
}

public enum DeviceCommandStatus: Equatable {
    case sending, awaitingConfirmation, failed(String)
    public var label: String {
        switch self {
        case .sending: return L10n.t("Enviando…", "Sending…")
        case .awaitingConfirmation: return L10n.t("Aguardando confirmação…", "Awaiting confirmation…")
        case .failed(let reason): return reason
        }
    }
}
