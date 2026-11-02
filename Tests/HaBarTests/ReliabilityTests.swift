import XCTest
import CryptoKit
import Combine
@testable import HaBar

@MainActor final class ReliabilityAPI: HomeAssistantAPI {
    weak var delegate: HomeAssistantClientDelegate?
    var snapshots: [[String: Any]] = []
    var fetchError: HAAPIError?
    var commandError: HAAPIError?
    var commands: [(String, String, [String: Any])] = []
    var socketConnections = 0
    var commandDelay: UInt64 = 0
    func fetchAreas(baseURL: String, token: String) async throws -> [[String: Any]] { [] }
    func fetchStates(baseURL: String, token: String) async throws -> [[String: Any]] {
        if let fetchError { throw fetchError }; return snapshots
    }
    func callService(baseURL: String, token: String, domain: String, service: String, payload: [String: Any]) async throws {
        commands.append((domain, service, payload))
        if commandDelay > 0 { try await Task.sleep(nanoseconds: commandDelay) }
        if let commandError { throw commandError }
    }
    func testConnection(baseURL: String, token: String) async -> ConnectionTestResult { .unreachable }
    func connectWebSocket(baseURL: String, token: String) { socketConnections += 1 }
    func disconnectWebSocket() {}
}

@MainActor final class ReliabilityTests: XCTestCase {
    override func setUp() {
        KeychainHelper.isIsolatedForTesting = true
        KeychainHelper.configDirectoryOverride = nil
        KeychainHelper.resetTestingStorage()
        L10n.forcedLanguage = "en"
    }
    override func tearDown() {
        KeychainHelper.resetTestingStorage()
        KeychainHelper.isIsolatedForTesting = false
        KeychainHelper.configDirectoryOverride = nil
        BiometricAuthHelper.evaluator = nil
        L10n.forcedLanguage = nil
    }
    private func makeStore(_ providedAPI: ReliabilityAPI? = nil) -> HomeAssistantStore {
        let api = providedAPI ?? ReliabilityAPI()
        let defaults = UserDefaults(suiteName: "habar.tests.\(UUID())")!
        defaults.set("en", forKey: "habar.language")
        let store = HomeAssistantStore(client: api, defaults: defaults, autoConnect: false)
        store.accessToken = "test-only"
        store.setDevicesForTesting([light()])
        return store
    }
    private func light() -> HADeviceItem {
        var item = HADeviceItem(id: "light.test", name: "Test", domain: .light, room: .unassigned, icon: "lightbulb")
        item.supportsBrightness = true; item.supportsRGB = true; item.supportsColor = true
        return item
    }
    private func settle(_ nanos: UInt64 = 220_000_000) async { try? await Task.sleep(nanoseconds: nanos) }

    func testOfflineFailureRestoresLastConfirmedState() async {
        let api = ReliabilityAPI(); api.commandError = .uncertain; api.fetchError = .connection
        let store = makeStore(api)
        store.toggleDevice("light.test")
        XCTAssertTrue(store.devices[0].isOn)
        await settle()
        XCTAssertFalse(store.devices[0].isOn)
        guard case .failed = store.commandStatuses["light.test"] else { return XCTFail("Failure must persist on the device") }
    }
    func testPowerOffCancelsPendingBrightness() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        store.setBrightness(for: "light.test", percentage: 50)
        store.turnOffAllLights()
        await settle()
        XCTAssertEqual(api.commands.map { $0.1 }, ["turn_off"])
    }
    func testBrightnessAndColorAreMerged() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        store.setBrightness(for: "light.test", percentage: 70)
        store.setCustomRGB(.ocean, for: "light.test")
        await settle()
        XCTAssertEqual(api.commands.count, 1)
        XCTAssertEqual(api.commands.first?.2["brightness_pct"] as? Int, 70)
        XCTAssertEqual(api.commands.first?.2["rgb_color"] as? [Int], RGBColor.ocean.jsonArray)
    }
    func testInFlightBrightnessCompletesBeforePowerOff() async {
        let api = ReliabilityAPI(); api.commandDelay = 100_000_000
        let store = makeStore(api)
        store.setBrightness(for: "light.test", percentage: 50)
        await settle(140_000_000)
        store.turnOffAllLights()
        await settle(350_000_000)
        XCTAssertEqual(api.commands.map { $0.1 }, ["turn_on", "turn_off"])
    }
    func testUnknownLockAndDoorAreNotPresentedAsSecure() throws {
        var lock = HADeviceItem(id: "lock.test", name: "Lock", domain: .lock, room: .unassigned, icon: "lock")
        HAEntityMapper.applyStateUpdate(["state": "unavailable"], to: &lock)
        XCTAssertEqual(lock.formattedStatusLine, "Unavailable")
        XCTAssertFalse(lock.canControl)
        let mapped = HAEntityMapper.mapStates([["entity_id": "binary_sensor.door", "state": "unknown", "attributes": ["device_class": "door"]]], entityToRoom: [:])
        XCTAssertEqual(try XCTUnwrap(mapped.devices.first).formattedStatusLine, "Unknown state")
    }
    func testUnavailableAtStartupRecoversAndNewEntityAppears() {
        let store = makeStore()
        store.clientDidReceiveStateUpdate(["entity_id": "lock.new", "state": "unavailable", "attributes": [:]])
        store.flushPendingStateUpdates()
        XCTAssertEqual(store.device(id: "lock.new")?.availability, .unavailable)
        store.clientDidReceiveStateUpdate(["entity_id": "lock.new", "state": "unlocked", "attributes": [:]])
        store.flushPendingStateUpdates()
        XCTAssertEqual(store.device(id: "lock.new")?.isOn, true)
        store.clientDidRemoveEntity("lock.new")
        XCTAssertNil(store.device(id: "lock.new"))
    }
    func testUnavailableCommandsAreBlocked() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        var item = light(); item.availability = .unavailable
        store.setDevicesForTesting([item])
        store.toggleDevice(item.id); store.setBrightness(for: item.id, percentage: 10)
        await settle()
        XCTAssertTrue(api.commands.isEmpty)
    }
    func testUnauthorizedSnapshotDoesNotStartSocket() async {
        let api = ReliabilityAPI(); api.fetchError = .unauthorized
        let store = makeStore(api)
        store.connectToHomeAssistant()
        await settle()
        XCTAssertEqual(store.connectionStatus, .unauthorized)
        XCTAssertEqual(api.socketConnections, 0)
        store.toggleDevice("light.test")
        await settle()
        XCTAssertFalse(store.device(id: "light.test")?.isOn ?? true)
        XCTAssertTrue(api.commands.isEmpty)
    }
    func testSnapshotAloneIsNotConnected() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        store.connectToHomeAssistant(); await settle()
        XCTAssertEqual(store.connectionStatus, .connecting)
        XCTAssertEqual(api.socketConnections, 1)
    }
    func testSwitchingServerDiscardsDelayedCommands() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        store.setBrightness(for: "light.test", percentage: 50)
        XCTAssertTrue(store.saveSettingsAndConnect(url: "https://new.example", token: "new-test-token"))
        await settle()
        XCTAssertTrue(api.commands.isEmpty)
        XCTAssertTrue(store.commandStatuses.isEmpty)
    }
    func testLockNeverOptimisticallyUnlocksAndRequiresAuthentication() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        let lock = HADeviceItem(id: "lock.test", name: "Lock", domain: .lock, room: .unassigned, icon: "lock")
        store.setDevicesForTesting([lock])
        BiometricAuthHelper.evaluator = { _ in false }
        store.requestToggle(lock); await settle()
        XCTAssertTrue(api.commands.isEmpty)
        BiometricAuthHelper.evaluator = { _ in true }
        store.requestToggle(lock); await settle()
        XCTAssertEqual(api.commands.map { $0.1 }, ["unlock"])
        XCTAssertFalse(store.devices[0].isOn)
        store.clientDidReceiveStateUpdate(["entity_id": lock.id, "state": "unlocked"])
        store.flushPendingStateUpdates()
        XCTAssertTrue(store.devices[0].isOn)
        XCTAssertNil(store.commandStatuses[lock.id])
    }
    func testMetricsUseTypedSensorUnitsAndSelection() {
        let store = makeStore()
        let values: [[String: Any]] = [
            ["entity_id":"sensor.power", "state":"0.35", "attributes":["device_class":"power", "unit_of_measurement":"kW"]],
            ["entity_id":"sensor.temp", "state":"77", "attributes":["device_class":"temperature", "unit_of_measurement":"°F"]]
        ]
        store.setDevicesForTesting(HAEntityMapper.mapStates(values, entityToRoom: [:]).devices)
        XCTAssertEqual(store.totalPowerWatts, 350)
        XCTAssertEqual(store.primaryTemperatureCelsius, 25)
        store.temperatureSensorId = "missing"
        XCTAssertNil(store.primaryTemperatureCelsius)
    }
    func testActiveLightsDoNotCountOtherDomainsOrGroups() {
        let store = makeStore()
        var light = light(); light.isOn = true
        var group = light; group = HADeviceItem(id: "light.group", name: "Group", domain: .light, room: .unassigned, icon: "lightbulb", isOn: true)
        group.memberEntityIds = [light.id]
        let fan = HADeviceItem(id: "fan.test", name: "Fan", domain: .fan, room: .unassigned, icon: "fan", isOn: true)
        store.setDevicesForTesting([light, group, fan])
        XCTAssertEqual(store.activeLightsCount, 1)
    }
    func testColorTemperatureOnlyDoesNotOfferRGB() throws {
        let mapped = HAEntityMapper.mapStates([["entity_id":"light.white", "state":"on", "attributes":["supported_color_modes":["color_temp"], "min_color_temp_kelvin":2200,"max_color_temp_kelvin":4000]]], entityToRoom: [:])
        let item = try XCTUnwrap(mapped.devices.first)
        XCTAssertTrue(item.supportsColorTemperature); XCTAssertFalse(item.supportsRGB)
        XCTAssertEqual(item.minKelvin, 2200); XCTAssertEqual(item.maxKelvin, 4000)
    }
    func testClimateHonorsHalfDegreeIncrementAndModeValidation() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        var item = HADeviceItem(id: "climate.test", name: "Climate", domain: .climate, room: .unassigned, icon: "snowflake")
        item.targetTemperature = 20; item.temperatureStep = 0.5; item.hvacModes = ["cool","off"]
        store.setDevicesForTesting([item])
        store.setClimateMode("invalid", for: item.id)
        store.setClimateTemperature(20.5, for: item.id)
        await settle()
        XCTAssertEqual(api.commands.count, 1)
        XCTAssertEqual(api.commands.first?.2["temperature"] as? Double, 20.5)
    }
    func testOlderEventDoesNotOverwriteNewerState() {
        var item = light()
        HAEntityMapper.applyStateUpdate(["state":"on", "last_updated":"2026-11-01T12:02:00Z"], to: &item)
        HAEntityMapper.applyStateUpdate(["state":"off", "last_updated":"2026-11-01T12:01:00Z"], to: &item)
        XCTAssertTrue(item.isOn)
    }
    func testOlderSceneEventsCannotReplaceTheLatestActivation() {
        let store = makeStore()
        store.clientDidReceiveStateUpdate(["entity_id":"scene.cinema", "state":"2026-11-01T12:02:00Z"])
        store.clientDidReceiveStateUpdate(["entity_id":"scene.boa_noite", "state":"2026-11-01T12:01:00Z"])
        store.clientDidReceiveStateUpdate(["entity_id":"scene.cinema", "state":"2026-11-01T12:00:00Z"])
        store.flushPendingStateUpdates()
        XCTAssertEqual(store.scenes.filter(\.isActive).map(\.id), ["scene.cinema"])
        XCTAssertEqual(store.scenes.first { $0.id == "scene.cinema" }?.lastActivated, HAEntityMapper.parseTimestamp("2026-11-01T12:02:00Z"))
    }
    func testBatchPublishesOnceForFortyChangedDevices() {
        let store = makeStore()
        let items = (0..<1000).map { HADeviceItem(id: "light.test_\($0)", name: "Test \($0)", domain: .light, room: .unassigned, icon: "lightbulb") }
        store.setDevicesForTesting(items)
        var publications = 0
        let observation = store.$devices.dropFirst().sink { _ in publications += 1 }
        for index in 0..<40 { store.clientDidReceiveStateUpdate(["entity_id":"light.test_\(index)", "state":"on"]) }
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.activeLightsCount, 40)
        withExtendedLifetime(observation) {}
    }

    func testCredentialMigrationRemovesPlaintextOnlyAfterSecureWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        KeychainHelper.configDirectoryOverride = dir
        let file = dir.appendingPathComponent("config.json")
        try Data("{\"server_url\":\"https://test.example\",\"token\":\"fake-secret\",\"custom\":true}".utf8).write(to: file)
        KeychainHelper.testingWriteError = -1
        XCTAssertEqual(KeychainHelper.loadToken(), "")
        XCTAssertTrue(try String(contentsOf: file).contains("fake-secret"))
        KeychainHelper.testingWriteError = nil
        XCTAssertEqual(KeychainHelper.loadToken(), "fake-secret")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertNil(config["token"]); XCTAssertEqual(config["custom"] as? Bool, true)
        XCTAssertEqual(KeychainHelper.loadToken(), "fake-secret")
        try KeychainHelper.saveConnection(url: "https://other.example", token: "other-fake")
        XCTAssertEqual(KeychainHelper.loadToken(), "other-fake")
    }
    func testDigestRejectsMismatchAndMissingChecksum() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertNoThrow(try AppUpdater.verifyDigest(file: file, expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        XCTAssertThrowsError(try AppUpdater.verifyDigest(file: file, expected: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try AppUpdater.verifyDigest(file: file, expected: nil))
    }
    func testArchiveTraversalLinksAndExpansionLimitAreRejected() {
        let valid = "HaBar.app/\nHaBar.app/Contents/MacOS/HaBar\n"
        XCTAssertNoThrow(try AppUpdater.validateArchiveListing(metadata: "-rw-r--r--", totals: "2 files, 100 bytes uncompressed", listing: valid))
        XCTAssertThrowsError(try AppUpdater.validateArchiveListing(metadata: "-rw-r--r--", totals: "2 files, 100 bytes uncompressed", listing: "HaBar.app/../../outside"))
        XCTAssertThrowsError(try AppUpdater.validateArchiveListing(metadata: "lrwxr-xr-x", totals: "2 files, 100 bytes uncompressed", listing: valid))
        XCTAssertThrowsError(try AppUpdater.validateArchiveListing(metadata: "-rw-r--r--", totals: "2 files, 999999999 bytes uncompressed", listing: valid))
    }
    func testUnsupportedMediaPowerControlDoesNotSend() async {
        let api = ReliabilityAPI(); let store = makeStore(api)
        var item = HADeviceItem(id: "media_player.readonly", name: "Speaker", domain: .mediaPlayer, room: .unassigned, icon: "speaker")
        item.reportedFeatures = 0
        store.setDevicesForTesting([item]); store.toggleDevice(item.id)
        await settle()
        XCTAssertTrue(api.commands.isEmpty)
    }
    func testClimateUsesServerTemperatureUnitWhenAttributeIsAbsent() throws {
        let states: [[String: Any]] = [["entity_id":"climate.test", "state":"heat", "attributes":["temperature": 72.0]]]
        var item = try XCTUnwrap(HAEntityMapper.mapStates(states, entityToRoom: [:], temperatureUnit: "°F").devices.first)
        XCTAssertEqual(item.temperatureUnit, "°F")
        HAEntityMapper.applyStateUpdate(["state":"heat", "attributes":["temperature":73.0]], to: &item)
        XCTAssertEqual(item.temperatureUnit, "°F")
    }

    func testInvalidUnsignedBundleFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AppUpdater.validateBundle(at: root, expectedTeam: "ABCDE12345"))
    }
}
