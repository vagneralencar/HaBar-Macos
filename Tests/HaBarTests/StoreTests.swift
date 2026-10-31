import XCTest
@testable import HaBar

@MainActor
final class MockHomeAssistantAPI: HomeAssistantAPI {
    weak var delegate: HomeAssistantClientDelegate?
    var serviceCallReturnValue = true
    var lastServiceCall: (domain: String, service: String, payload: [String: Any])?
    var statesToReturn: [[String: Any]] = []

    func fetchAreas(baseURL: String, token: String) async -> [[String: Any]]? {
        []
    }

    func fetchStates(baseURL: String, token: String) async -> [[String: Any]]? {
        statesToReturn
    }

    func callService(baseURL: String, token: String, domain: String, service: String, payload: [String: Any]) async -> Bool {
        lastServiceCall = (domain, service, payload)
        return serviceCallReturnValue
    }

    func testConnection(baseURL: String, token: String) async -> ConnectionTestResult {
        .success(version: "2024.10.1")
    }

    func connectWebSocket(baseURL: String, token: String) {}
    func disconnectWebSocket() {}
}

@MainActor
final class StoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainHelper.isIsolatedForTesting = true
    }

    override func tearDown() {
        KeychainHelper.isIsolatedForTesting = false
        super.tearDown()
    }

    func testReconnectDelayBackoff() {
        XCTAssertEqual(HomeAssistantStore.reconnectDelay(forAttempt: 0), 2)
        XCTAssertEqual(HomeAssistantStore.reconnectDelay(forAttempt: 1), 4)
        XCTAssertEqual(HomeAssistantStore.reconnectDelay(forAttempt: 2), 8)
        XCTAssertEqual(HomeAssistantStore.reconnectDelay(forAttempt: 3), 16)
        XCTAssertEqual(HomeAssistantStore.reconnectDelay(forAttempt: 4), 30) // capped at 30s
        XCTAssertEqual(HomeAssistantStore.reconnectDelay(forAttempt: 10), 30)
    }

    func testToggleFavorite() {
        let mockAPI = MockHomeAssistantAPI()
        let defaults = UserDefaults(suiteName: "test_favorites_\(UUID().uuidString)")!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)

        guard let first = store.devices.first else {
            XCTFail("Expected default mockup devices")
            return
        }

        let initialFav = first.isFavorite
        store.toggleFavorite(first.id)

        let updated = store.devices.first(where: { $0.id == first.id })
        XCTAssertEqual(updated?.isFavorite, !initialFav)

        // Toggling again restores it
        store.toggleFavorite(first.id)
        let restored = store.devices.first(where: { $0.id == first.id })
        XCTAssertEqual(restored?.isFavorite, initialFav)
    }

    func testOptimisticUpdateRollbackOnFailure() async {
        let mockAPI = MockHomeAssistantAPI()
        mockAPI.serviceCallReturnValue = false // simulate network failure
        let defaults = UserDefaults(suiteName: "test_rollback_\(UUID().uuidString)")!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)
        store.serverURLString = "http://test.local:8123"
        store.accessToken = "test_token"

        guard let light = store.devices.first(where: { $0.domain == .light }) else {
            XCTFail("Expected light in demo store")
            return
        }

        let initialIsOn = light.isOn
        mockAPI.statesToReturn = [
            ["entity_id": light.id, "state": initialIsOn ? "on" : "off", "attributes": [:]]
        ]

        store.toggleDevice(light.id)

        // Optimistically changed immediately
        let optimistic = store.devices.first(where: { $0.id == light.id })
        XCTAssertEqual(optimistic?.isOn, !initialIsOn)

        // Wait for async service call and rollback
        try? await Task.sleep(nanoseconds: 150_000_000)

        let reverted = store.devices.first(where: { $0.id == light.id })
        XCTAssertEqual(reverted?.isOn, initialIsOn)
        XCTAssertNotNil(store.toast)
        XCTAssertTrue(store.toast?.isError == true)
    }

    func testConfirmationRequestForLocks() async {
        let mockAPI = MockHomeAssistantAPI()
        let defaults = UserDefaults(suiteName: "test_lock_\(UUID().uuidString)")!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)
        store.serverURLString = "http://test.local:8123"
        store.accessToken = "test_token"

        // Inject locked lock device
        var lock = HADeviceItem(id: "lock.porta", name: "Porta", domain: .lock, room: .salaJantar, icon: "lock.fill", isOn: false)
        lock.isFavorite = true
        var current = store.devices
        current.append(lock)
        store.setDevicesForTesting(current)

        // Toggling locked lock triggers pending confirmation
        store.requestToggle(lock)
        XCTAssertNotNil(store.pendingConfirmation)
        XCTAssertTrue(store.pendingConfirmation?.title.contains("Destrancar") == true)

        // Executing the confirmation action calls service
        store.pendingConfirmation?.action()

        // Wait for async dispatch
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mockAPI.lastServiceCall?.domain, "lock")
        XCTAssertEqual(mockAPI.lastServiceCall?.service, "unlock")
    }

    func testThemeModePersistence() {
        let mockAPI = MockHomeAssistantAPI()
        let suiteName = "test_theme_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)

        XCTAssertEqual(store.themeMode, .dark)
        store.themeMode = .light

        // Re-creating store with same defaults preserves selection
        let store2 = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)
        XCTAssertEqual(store2.themeMode, .light)
    }

    func testLanguagePreferenceAndBilingualStrings() {
        let mockAPI = MockHomeAssistantAPI()
        let suiteName = "test_lang_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)

        store.language = .en
        XCTAssertEqual(L10n.forcedLanguage, "en")
        XCTAssertEqual(L10n.t("Ligar", "Turn on"), "Turn on")

        store.language = .pt
        XCTAssertEqual(L10n.forcedLanguage, "pt")
        XCTAssertEqual(L10n.t("Ligar", "Turn on"), "Ligar")
    }

    func testOpeningRoomPreference() {
        let mockAPI = MockHomeAssistantAPI()
        let suiteName = "test_room_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)

        store.defaultOpeningRoomId = HARoom.escritorio.id
        store.selectedRoom = .salaTV
        XCTAssertEqual(store.selectedRoom.id, HARoom.salaTV.id)

        store.applyOpeningRoomPreference()
        XCTAssertEqual(store.selectedRoom.id, HARoom.escritorio.id)
    }

    func testInAppUpdateWorkflow() async {
        AppInfo.versionOverride = "1.0.0"
        defer { AppInfo.versionOverride = nil }

        let mockAPI = MockHomeAssistantAPI()
        let suiteName = "test_updater_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HomeAssistantStore(client: mockAPI, defaults: defaults, autoConnect: false)

        let mockRelease = ReleaseInfo(
            version: "9.9.9",
            url: URL(string: "https://github.com/vagneralencar/HaBar-Macos/releases/tag/v9.9.9")!,
            downloadURL: URL(string: "https://github.com/vagneralencar/HaBar-Macos/releases/download/v9.9.9/HaBar.zip")!,
            body: "Super update",
            assetSize: 1024,
            sha256: "testsha"
        )

        // 1. Check for update
        await store.checkForUpdates(userInitiated: true, fetcher: { mockRelease })
        XCTAssertEqual(store.availableUpdate?.version, "9.9.9")
        if case .available(let rel) = store.updateStatus {
            XCTAssertEqual(rel.version, "9.9.9")
        } else {
            XCTFail("Expected status to be available")
        }

        // 2. Start download
        let dummyStagedURL = URL(fileURLWithPath: "/tmp/dummy_HaBar.app")
        await store.startInAppUpdate(downloader: { release, progressHandler in
            progressHandler(0.5, 512, 1024)
            progressHandler(1.0, 1024, 1024)
            return dummyStagedURL
        })

        if case .readyToInstall(let rel, let url) = store.updateStatus {
            XCTAssertEqual(rel.version, "9.9.9")
            XCTAssertEqual(url, dummyStagedURL)
        } else {
            XCTFail("Expected status to be readyToInstall")
        }

        // 3. Apply update & restart
        var installedURL: URL?
        store.applyUpdateAndRestart(installer: { url in
            installedURL = url
        })
        XCTAssertEqual(installedURL, dummyStagedURL)
        XCTAssertEqual(store.updateStatus, .installing)

        // 4. Dismiss banner
        store.dismissUpdateBanner()
        XCTAssertTrue(store.isDismissedUpdateBanner)
    }
}
