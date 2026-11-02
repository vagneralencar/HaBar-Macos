import XCTest
@testable import HaBar

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var status = 200
    static var body = Data("[]".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let code = Self.status; let data = Self.body
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(status: Int = 200, body: String = "[]") {
        lock.lock(); defer { lock.unlock() }
        requests = []; self.status = status; self.body = Data(body.utf8)
    }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor private final class ClientSpy: HomeAssistantClientDelegate {
    var authenticated = false
    var unauthorized = false
    var disconnected = false
    var removed: [String] = []
    var received: [[String: Any]] = []
    func clientDidAuthenticate(host: String) { authenticated = true }
    func clientDidFailAuthentication() { unauthorized = true }
    func clientDidReceiveStateUpdate(_ stateObject: [String : Any]) { received.append(stateObject) }
    func clientDidRemoveEntity(_ entityId: String) { removed.append(entityId) }
    func clientDidDisconnect() { disconnected = true }
}

@MainActor final class ClientTests: XCTestCase {
    private func makeClient() -> HomeAssistantClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return HomeAssistantClient(configuration: config)
    }
    func testChangingServerUsesOnlyNewAddressAndToken() async throws {
        StubProtocol.reset()
        let client = makeClient()
        _ = try await client.fetchStates(baseURL: "https://first.invalid", token: "first-test")
        client.resetSession()
        _ = try await client.fetchStates(baseURL: "https://second.invalid", token: "second-test")
        let requests = StubProtocol.captured()
        XCTAssertEqual(requests.map { $0.url?.host }, ["first.invalid", "second.invalid"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer second-test")
    }
    func testConnectionTestChecksExactlyEnteredURL() async {
        StubProtocol.reset(body: "{\"version\":\"2026.1\"}")
        let result = await makeClient().testConnection(baseURL: "https://entered.invalid", token: "test")
        XCTAssertEqual(result, .success(version: "2026.1"))
        XCTAssertEqual(StubProtocol.captured().map { $0.url?.host }, ["entered.invalid"])
    }
    func testUnauthorizedIsPreservedAndServiceIsNotRetried() async {
        StubProtocol.reset(status: 401)
        let client = makeClient()
        do { _ = try await client.fetchStates(baseURL: "https://test.invalid", token: "test"); XCTFail("Expected 401") }
        catch { XCTAssertEqual(error as? HAAPIError, .unauthorized) }
        StubProtocol.reset(status: 403)
        let forbidden = await client.testConnection(baseURL: "https://test.invalid", token: "test")
        XCTAssertEqual(forbidden, .forbidden)
        StubProtocol.reset(status: 500)
        do { try await client.callService(baseURL: "https://test.invalid", token: "test", domain: "script", service: "turn_on", payload: ["entity_id":"script.test"]); XCTFail("Expected error") }
        catch { XCTAssertEqual(error as? HAAPIError, .http(500)) }
        XCTAssertEqual(StubProtocol.captured().count, 1)
    }
    func testClimateUnitComesFromServerConfiguration() async throws {
        StubProtocol.reset(body: "{\"unit_system\":{\"temperature\":\"°F\"}}")
        let unit = try await makeClient().fetchTemperatureUnit(baseURL: "https://test.invalid", token: "test")
        XCTAssertEqual(unit, "°F")
        XCTAssertEqual(StubProtocol.captured().first?.url?.path, "/api/config")
    }
    func testWebSocketWaitsForSubscriptionAcknowledgement() {
        let client = makeClient(); let spy = ClientSpy(); client.delegate = spy
        client.handle(.string("{\"type\":\"auth_ok\"}"), generation: 0, baseURL: "https://test.invalid", token: "test")
        XCTAssertFalse(spy.authenticated)
        client.handle(.string("{\"type\":\"result\",\"id\":1,\"success\":true}"), generation: 0, baseURL: "https://test.invalid", token: "test")
        XCTAssertTrue(spy.authenticated)
        client.disconnectWebSocket()
    }
    func testRejectedSubscriptionNeverMarksConnected() {
        let client = makeClient(); let spy = ClientSpy(); client.delegate = spy
        client.handle(.string("{\"type\":\"auth_ok\"}"), generation: 0, baseURL: "https://test.invalid", token: "test")
        client.handle(.string("{\"type\":\"result\",\"id\":1,\"success\":false}"), generation: 0, baseURL: "https://test.invalid", token: "test")
        XCTAssertFalse(spy.authenticated); XCTAssertTrue(spy.disconnected)
    }
    func testRemovedEntityIsForwarded() {
        let client = makeClient(); let spy = ClientSpy(); client.delegate = spy
        client.handle(.string("{\"type\":\"event\",\"event\":{\"data\":{\"entity_id\":\"light.test\",\"new_state\":null}}}"), generation: 0, baseURL: "https://test.invalid", token: "test")
        XCTAssertEqual(spy.removed, ["light.test"])
    }
    func testURLValidationRejectsCredentialsAndUnsupportedSchemes() {
        XCTAssertNil(HomeAssistantURL.normalized("ftp://test.invalid"))
        XCTAssertNil(HomeAssistantURL.normalized("https://user:secret@test.invalid"))
        XCTAssertNil(HomeAssistantURL.normalized("https://test.invalid?token=test"))
        XCTAssertEqual(HomeAssistantURL.normalized(" HTTPS://TEST.invalid/ "), "https://test.invalid")
        XCTAssertNotNil(HomeAssistantURL.normalized("http://[::1]:8123"))
    }
}
