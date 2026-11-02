import Foundation

public enum ConnectionTestResult: Equatable, Sendable {
    case success(version: String), unauthorized, forbidden, unreachable, invalidURL
}

public enum HAAPIError: LocalizedError, Equatable {
    case invalidURL, unauthorized, forbidden, invalidResponse, http(Int), connection, uncertain, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return L10n.t("URL inválida. Use http:// ou https:// sem credenciais na URL.", "Invalid URL. Use http:// or https:// without credentials in the URL.")
        case .unauthorized: return L10n.t("Token inválido ou expirado.", "Invalid or expired token.")
        case .forbidden: return L10n.t("Sua conta não tem permissão para esta ação.", "Your account doesn't have permission for this action.")
        case .invalidResponse: return L10n.t("Resposta inválida do servidor.", "Invalid server response.")
        case .http(let code): return L10n.t("O servidor recusou a solicitação", "The server rejected the request") + " (HTTP \(code))."
        case .connection: return L10n.t("Sem conexão com o servidor.", "Couldn't connect to the server.")
        case .uncertain: return L10n.t("Sem confirmação. Verifique o dispositivo antes de tentar novamente.", "No confirmation. Check the device before retrying.")
        case .cancelled: return L10n.t("Solicitação cancelada.", "Request cancelled.")
        }
    }
}

public enum HomeAssistantURL {
    public static func normalized(_ input: String) -> String? {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { return nil }
        c.scheme = scheme
        c.host = host.lowercased()
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url?.absoluteString
    }
}

@MainActor public protocol HomeAssistantClientDelegate: AnyObject {
    func clientDidAuthenticate(host: String)
    func clientDidFailAuthentication()
    func clientDidReceiveStateUpdate(_ stateObject: [String: Any])
    func clientDidRemoveEntity(_ entityId: String)
    func clientDidDisconnect()
}

@MainActor public protocol HomeAssistantAPI: AnyObject {
    var delegate: HomeAssistantClientDelegate? { get set }
    func fetchAreas(baseURL: String, token: String) async throws -> [[String: Any]]
    func fetchStates(baseURL: String, token: String) async throws -> [[String: Any]]
    func callService(baseURL: String, token: String, domain: String, service: String, payload: [String: Any]) async throws
    func testConnection(baseURL: String, token: String) async -> ConnectionTestResult
    func connectWebSocket(baseURL: String, token: String)
    func disconnectWebSocket()
    func resetSession()
    func fetchTemperatureUnit(baseURL: String, token: String) async throws -> String
}

public extension HomeAssistantAPI {
    func resetSession() { disconnectWebSocket() }
    func fetchTemperatureUnit(baseURL: String, token: String) async throws -> String { "°C" }
}
public extension HomeAssistantClientDelegate { func clientDidRemoveEntity(_ entityId: String) {} }

/// Credentials never follow redirects or implicit alternate hosts.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor public final class HomeAssistantClient: HomeAssistantAPI {
    public weak var delegate: HomeAssistantClientDelegate?
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var socketGeneration = 0
    private var sessionGeneration = 0
    private var wsMessageId = 0
    private var subscriptionId: Int?
    private var pongId: Int?
    private var keepAliveTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private static let areaTemplateQuery = "{% set ns = namespace(areas=[]) %}{% for a in areas() %}{% set ns.areas = ns.areas + [{\"id\": a, \"name\": area_name(a), \"entities\": area_entities(a)}] %}{% endfor %}{{ ns.areas | tojson }}"

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func resetSession() {
        sessionGeneration += 1
        disconnectWebSocket()
    }

    private func request(baseURL: String, path: String, token: String, method: String = "GET", payload: [String: Any]? = nil) throws -> URLRequest {
        guard let base = HomeAssistantURL.normalized(baseURL), let url = URL(string: base + path) else { throw HAAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let payload { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        return request
    }

    private func perform(_ request: URLRequest, command: Bool = false) async throws -> Data {
        let generation = sessionGeneration
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch {
            if Task.isCancelled || generation != sessionGeneration { throw HAAPIError.cancelled }
            throw command ? HAAPIError.uncertain : HAAPIError.connection
        }
        guard generation == sessionGeneration, !Task.isCancelled else { throw HAAPIError.cancelled }
        guard let response = result.1 as? HTTPURLResponse else { throw HAAPIError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return result.0
        case 401: throw HAAPIError.unauthorized
        case 403: throw HAAPIError.forbidden
        default: throw HAAPIError.http(response.statusCode)
        }
    }

    private func array(_ request: URLRequest) async throws -> [[String: Any]] {
        let data = try await perform(request)
        return try await Task.detached {
            guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HAAPIError.invalidResponse }
            return result
        }.value
    }

    public func fetchAreas(baseURL: String, token: String) async throws -> [[String: Any]] {
        try await array(request(baseURL: baseURL, path: "/api/template", token: token, method: "POST", payload: ["template": Self.areaTemplateQuery]))
    }
    public func fetchStates(baseURL: String, token: String) async throws -> [[String: Any]] {
        try await array(request(baseURL: baseURL, path: "/api/states", token: token))
    }
    public func callService(baseURL: String, token: String, domain: String, service: String, payload: [String: Any]) async throws {
        _ = try await perform(request(baseURL: baseURL, path: "/api/services/\(domain)/\(service)", token: token, method: "POST", payload: payload), command: true)
    }
    public func fetchTemperatureUnit(baseURL: String, token: String) async throws -> String {
        let data = try await perform(request(baseURL: baseURL, path: "/api/config", token: token))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let units = json["unit_system"] as? [String: Any], let unit = units["temperature"] as? String,
              ["°C", "°F", "K"].contains(unit) else { throw HAAPIError.invalidResponse }
        return unit
    }
    public func testConnection(baseURL: String, token: String) async -> ConnectionTestResult {
        do {
            let data = try await perform(request(baseURL: baseURL, path: "/api/config", token: token))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = json["version"] as? String else { return .unreachable }
            return .success(version: version)
        } catch HAAPIError.invalidURL { return .invalidURL }
        catch HAAPIError.unauthorized { return .unauthorized }
        catch HAAPIError.forbidden { return .forbidden }
        catch { return .unreachable }
    }

    public func connectWebSocket(baseURL: String, token: String) {
        disconnectWebSocket()
        guard let base = HomeAssistantURL.normalized(baseURL), var c = URLComponents(string: base + "/api/websocket") else { delegate?.clientDidDisconnect(); return }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        guard let url = c.url else { return }
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        let generation = socketGeneration
        task.resume()
        listen(on: task, generation: generation, baseURL: base, token: token)
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, generation == self.socketGeneration else { return }
            self.socketDidClose()
        }
    }
    public func disconnectWebSocket() {
        socketGeneration += 1
        keepAliveTask?.cancel(); handshakeTask?.cancel()
        keepAliveTask = nil; handshakeTask = nil; subscriptionId = nil; pongId = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
    private func socketDidClose() { disconnectWebSocket(); delegate?.clientDidDisconnect() }
    private func listen(on task: URLSessionWebSocketTask, generation: Int, baseURL: String, token: String) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == self.socketGeneration else { return }
                switch result {
                case .success(let message):
                    self.handle(message, generation: generation, baseURL: baseURL, token: token)
                    if generation == self.socketGeneration { self.listen(on: task, generation: generation, baseURL: baseURL, token: token) }
                case .failure: self.socketDidClose()
                }
            }
        }
    }
    func handle(_ message: URLSessionWebSocketTask.Message, generation: Int, baseURL: String, token: String) {
        let data: Data?
        switch message { case .string(let s): data = s.data(using: .utf8); case .data(let d): data = d; @unknown default: data = nil }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch json["type"] as? String {
        case "auth_required": sendJSON(["type": "auth", "access_token": token])
        case "auth_ok":
            wsMessageId += 1; subscriptionId = wsMessageId
            sendJSON(["id": wsMessageId, "type": "subscribe_events", "event_type": "state_changed"])
        case "result" where json["id"] as? Int == subscriptionId:
            guard json["success"] as? Bool == true else { socketDidClose(); return }
            handshakeTask?.cancel(); handshakeTask = nil
            startKeepAlive(generation: generation)
            delegate?.clientDidAuthenticate(host: URL(string: baseURL)?.host ?? baseURL)
        case "auth_invalid": disconnectWebSocket(); delegate?.clientDidFailAuthentication()
        case "pong": if json["id"] as? Int == pongId { pongId = nil }
        case "event":
            guard let event = json["event"] as? [String: Any], let eventData = event["data"] as? [String: Any] else { return }
            if let state = eventData["new_state"] as? [String: Any] { delegate?.clientDidReceiveStateUpdate(state) }
            else if let id = eventData["entity_id"] as? String { delegate?.clientDidRemoveEntity(id) }
        default: break
        }
    }
    private func startKeepAlive(generation: Int) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled, generation == self.socketGeneration else { return }
                self.wsMessageId += 1; self.pongId = self.wsMessageId
                self.sendJSON(["id": self.wsMessageId, "type": "ping"])
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, generation == self.socketGeneration else { return }
                if self.pongId != nil { self.socketDidClose(); return }
            }
        }
    }
    private func sendJSON(_ dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary), let text = String(data: data, encoding: .utf8) else { return }
        let generation = socketGeneration
        webSocketTask?.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.socketGeneration else { return }
                self.socketDidClose()
            }
        }
    }
}
