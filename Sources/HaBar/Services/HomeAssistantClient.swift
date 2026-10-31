import Foundation

public enum ConnectionTestResult: Equatable, Sendable {
    case success(version: String)
    case unauthorized
    case unreachable
    case invalidURL
}

@MainActor
public protocol HomeAssistantClientDelegate: AnyObject {
    func clientDidAuthenticate(host: String)
    func clientDidFailAuthentication()
    func clientDidReceiveStateUpdate(_ stateObject: [String: Any])
    func clientDidDisconnect()
}

/// Abstraction over the Home Assistant transport so the store can be unit-tested with a mock.
@MainActor
public protocol HomeAssistantAPI: AnyObject {
    var delegate: HomeAssistantClientDelegate? { get set }
    func fetchAreas(baseURL: String, token: String) async -> [[String: Any]]?
    func fetchStates(baseURL: String, token: String) async -> [[String: Any]]?
    func callService(baseURL: String, token: String, domain: String, service: String, payload: [String: Any]) async -> Bool
    func testConnection(baseURL: String, token: String) async -> ConnectionTestResult
    func connectWebSocket(baseURL: String, token: String)
    func disconnectWebSocket()
}

@MainActor
public final class HomeAssistantClient: HomeAssistantAPI {
    public weak var delegate: HomeAssistantClientDelegate?

    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    /// Incremented whenever a socket is closed or replaced, so late callbacks from old sockets are ignored.
    private var socketGeneration = 0
    private var wsMessageId = 1
    private var awaitingPong = false
    private var keepAliveTask: Task<Void, Never>?
    private var resolvedBaseURL: String?

    private static let keepAliveInterval: UInt64 = 25_000_000_000
    private static let pongTimeout: UInt64 = 10_000_000_000
    private static let areaTemplateQuery = "{% set ns = namespace(areas=[]) %}{% for a in areas() %}{% set ns.areas = ns.areas + [{\"id\": a, \"name\": area_name(a), \"entities\": area_entities(a)}] %}{% endfor %}{{ ns.areas | tojson }}"

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - REST

    public func fetchAreas(baseURL: String, token: String) async -> [[String: Any]]? {
        for candidate in candidateURLs(for: baseURL) {
            guard var request = buildRequest(baseURL: candidate, path: "/api/template", token: token, method: "POST") else { continue }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["template": Self.areaTemplateQuery])
            if let parsed = await performJSONArray(request) {
                resolvedBaseURL = candidate
                return parsed
            }
        }
        return nil
    }

    public func fetchStates(baseURL: String, token: String) async -> [[String: Any]]? {
        for candidate in candidateURLs(for: baseURL) {
            guard let request = buildRequest(baseURL: candidate, path: "/api/states", token: token, method: "GET") else { continue }
            if let parsed = await performJSONArray(request) {
                resolvedBaseURL = candidate
                return parsed
            }
        }
        return nil
    }

    public func callService(
        baseURL: String,
        token: String,
        domain: String,
        service: String,
        payload: [String: Any]
    ) async -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return false }

        for candidate in candidateURLs(for: baseURL) {
            guard var request = buildRequest(
                baseURL: candidate,
                path: "/api/services/\(domain)/\(service)",
                token: trimmedToken,
                method: "POST"
            ) else { continue }

            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                resolvedBaseURL = candidate
                return true
            }
        }
        return false
    }

    public func testConnection(baseURL: String, token: String) async -> ConnectionTestResult {
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        guard URL(string: trimmedBase)?.host != nil else { return .invalidURL }

        var sawUnauthorized = false
        for candidate in candidateURLs(for: trimmedBase) {
            guard let request = buildRequest(baseURL: candidate, path: "/api/config", token: token, method: "GET") else { continue }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 {
                sawUnauthorized = true
                continue
            }
            if (200...299).contains(http.statusCode) {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return .success(version: (json?["version"] as? String) ?? "?")
            }
        }
        return sawUnauthorized ? .unauthorized : .unreachable
    }

    // MARK: - WebSocket

    public func connectWebSocket(baseURL: String, token: String) {
        disconnectWebSocket()

        let base = (resolvedBaseURL ?? baseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let wsBase = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let wsURL = URL(string: "\(wsBase)/api/websocket") else { return }

        let task = session.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()
        listen(on: task, generation: socketGeneration, baseURL: base, token: token)
    }

    public func disconnectWebSocket() {
        socketGeneration += 1
        keepAliveTask?.cancel()
        keepAliveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Helpers

    private func performJSONArray(_ request: URLRequest) async -> [[String: Any]]? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// The base URL that last worked goes first, followed by the configured URL and the optional fallback.
    func candidateURLs(for baseURL: String) -> [String] {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var ordered: [String] = []
        if let resolved = resolvedBaseURL { ordered.append(resolved) }
        ordered.append(clean)
        if let fallback = KeychainHelper.fallbackURLString {
            ordered.append(fallback.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    private func buildRequest(baseURL: String, path: String, token: String, method: String) -> URLRequest? {
        let cleanBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBase)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func listen(on task: URLSessionWebSocketTask, generation: Int, baseURL: String, token: String) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == self.socketGeneration else { return }
                switch result {
                case .success(let message):
                    self.handle(message, generation: generation, baseURL: baseURL, token: token)
                    guard generation == self.socketGeneration else { return }
                    self.listen(on: task, generation: generation, baseURL: baseURL, token: token)
                case .failure:
                    self.socketDidClose()
                }
            }
        }
    }

    private func socketDidClose() {
        disconnectWebSocket()
        delegate?.clientDidDisconnect()
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, generation: Int, baseURL: String, token: String) {
        let rawData: Data?
        switch message {
        case .string(let text): rawData = text.data(using: .utf8)
        case .data(let data): rawData = data
        @unknown default: rawData = nil
        }

        guard let data = rawData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "auth_required":
            sendJSON(["type": "auth", "access_token": token])
        case "auth_ok":
            wsMessageId += 1
            sendJSON(["id": wsMessageId, "type": "subscribe_events", "event_type": "state_changed"])
            startKeepAlive(generation: generation)
            delegate?.clientDidAuthenticate(host: URL(string: baseURL)?.host ?? baseURL)
        case "auth_invalid":
            disconnectWebSocket()
            delegate?.clientDidFailAuthentication()
        case "pong":
            awaitingPong = false
        case "event":
            guard let event = json["event"] as? [String: Any],
                  let eventData = event["data"] as? [String: Any],
                  let newState = eventData["new_state"] as? [String: Any] else { return }
            delegate?.clientDidReceiveStateUpdate(newState)
        default:
            break
        }
    }

    /// Detects half-open sockets (Wi-Fi drops, server restarts) that never report a failure by themselves.
    private func startKeepAlive(generation: Int) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepAliveInterval)
                guard let self, !Task.isCancelled, generation == self.socketGeneration else { return }
                self.awaitingPong = true
                self.wsMessageId += 1
                self.sendJSON(["id": self.wsMessageId, "type": "ping"])

                try? await Task.sleep(nanoseconds: Self.pongTimeout)
                guard !Task.isCancelled, generation == self.socketGeneration else { return }
                if self.awaitingPong {
                    self.socketDidClose()
                    return
                }
            }
        }
    }

    private func sendJSON(_ dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }
}
