import Foundation
import SwiftUI

public enum HAConnectionStatus: Equatable {
    case connected(host: String)
    case connecting
    case reconnecting(host: String)
    case unauthorized
    case demoMode(host: String)

    public var labelText: String {
        switch self {
        case .connected(let host):
            return L10n.t("\(host) • Conectado", "\(host) • Connected")
        case .demoMode(let host):
            return L10n.t("\(host) • Modo demo", "\(host) • Demo mode")
        case .connecting:
            return L10n.t("Conectando ao Home Assistant…", "Connecting to Home Assistant…")
        case .reconnecting:
            return L10n.t("Sem conexão • reconectando…", "Offline • reconnecting…")
        case .unauthorized:
            return L10n.t("Token inválido ou expirado", "Invalid or expired token")
        }
    }

    public var isHealthy: Bool {
        switch self {
        case .connected, .demoMode: return true
        case .connecting, .reconnecting, .unauthorized: return false
        }
    }
}

public struct ToastMessage: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let isError: Bool
}

public enum AppThemeMode: String, CaseIterable, Sendable {
    case dark
    case light
    case system

    public var title: String {
        switch self {
        case .dark: return L10n.t("Escuro", "Dark")
        case .light: return L10n.t("Claro", "Light")
        case .system: return L10n.t("Sistema", "System")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// A destructive/safety-sensitive action waiting for the user's explicit confirmation.
public struct ConfirmationRequest: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let action: () -> Void
}

@MainActor
public final class HomeAssistantStore: ObservableObject, HomeAssistantClientDelegate {
    // MARK: - Published state

    @Published public private(set) var rooms: [HARoom] = HARoom.defaultRooms
    @Published public private(set) var scenes: [HASceneItem] = HASceneItem.defaultMockupScenes
    @Published public private(set) var devices: [HADeviceItem] = HADeviceItem.defaultMockupDevices {
        didSet { rebuildIndexMap() }
    }
    @Published public var selectedRoom: HARoom = .favorites
    @Published public var searchQuery: String = ""
    @Published public var isSearchVisible: Bool = false
    @Published public var selectedDeviceForDetail: HADeviceItem? = nil
    @Published public var isShowingSettings: Bool = false

    @Published public var serverURLString: String
    @Published public var accessToken: String
    @Published public private(set) var connectionStatus: HAConnectionStatus = .connecting
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var toast: ToastMessage?
    @Published public var pendingConfirmation: ConfirmationRequest?
    @Published public private(set) var availableUpdate: ReleaseInfo?
    @Published public private(set) var updateCheckMessage: String?

    @Published public var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    @Published public var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    @Published public var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    public let isScreenshotPreview: Bool

    // MARK: - Private state

    private enum Keys {
        static let favoriteOverrides = "habar.favoriteOverrides"
        static let hotKeyEnabled = "habar.hotKeyEnabled"
        static let autoCheckUpdates = "habar.autoCheckUpdates"
        static let themeMode = "habar.themeMode"
    }

    private let client: HomeAssistantAPI
    private let defaults: UserDefaults
    private var deviceIndexById: [String: Int] = [:]
    private var entityToRoomMap: [String: HARoom] = [:]
    private var favoriteOverrides: [String: Bool]
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var hasLoadedOnce = false
    private var activeSceneId: String?
    private var sceneActivatedAt = Date.distantPast
    private let sceneGracePeriod: TimeInterval = 3

    // MARK: - Init

    public convenience init(defaults: UserDefaults = .standard, autoConnect: Bool = true) {
        self.init(client: HomeAssistantClient(), defaults: defaults, autoConnect: autoConnect)
    }

    public init(
        client: HomeAssistantAPI,
        defaults: UserDefaults = .standard,
        autoConnect: Bool = true
    ) {
        self.client = client
        self.defaults = defaults
        self.isScreenshotPreview = false
        self.favoriteOverrides = defaults.dictionary(forKey: Keys.favoriteOverrides) as? [String: Bool] ?? [:]
        self.hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        self.autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        self.themeMode = defaults.string(forKey: Keys.themeMode).flatMap(AppThemeMode.init) ?? .dark

        let savedURL = KeychainHelper.serverURLString
        let savedToken = KeychainHelper.loadToken()
        self.serverURLString = savedURL
        self.accessToken = savedToken

        self.client.delegate = self

        if savedToken.isEmpty {
            // First run: show demo content and guide the user straight to the settings screen.
            connectionStatus = .demoMode(host: Self.extractHost(from: savedURL))
            isShowingSettings = autoConnect
        } else {
            // Never flash fake demo data when a real server is configured.
            rooms = [.favorites]
            scenes = []
            devices = []
            isLoading = autoConnect
            if autoConnect { connectToHomeAssistant() }
        }
        rebuildIndexMap()
    }

    public static func makeScreenshotDemoStore() -> HomeAssistantStore {
        HomeAssistantStore(isScreenshotPreview: true)
    }

    private init(isScreenshotPreview: Bool) {
        self.client = HomeAssistantClient()
        self.defaults = .standard
        self.isScreenshotPreview = isScreenshotPreview
        self.favoriteOverrides = [:]
        self.hotKeyEnabled = true
        self.autoCheckUpdates = false
        self.themeMode = .dark
        self.serverURLString = "http://homeassistant.local:8123"
        self.accessToken = ""
        self.connectionStatus = .connected(host: "homeassistant.local")
        self.activeSceneId = HASceneItem.defaultMockupScenes.first?.id
        self.scenes = HASceneItem.defaultMockupScenes.map { scene in
            var copy = scene
            copy.isActive = (scene.id == activeSceneId)
            return copy
        }
        self.devices = HADeviceItem.defaultMockupDevices
        rebuildIndexMap()
    }

    // MARK: - Derived queries

    public var hasCredentials: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var activeLightsCount: Int {
        devices.reduce(0) { $0 + ($1.domain.countsAsActive && $1.isOn ? 1 : 0) }
    }

    public func hasActiveDevice(in room: HARoom) -> Bool {
        devices.contains { device in
            guard device.domain.countsAsActive, device.isOn else { return false }
            return room.id == HARoom.favorites.id ? device.isFavorite : device.room.id == room.id
        }
    }

    public var filteredScenes: [HASceneItem] { scenes }

    /// While searching, results span every room; otherwise the selected room (or favorites) is shown.
    public var filteredDevices: [HADeviceItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return devices.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
            }
        }
        if selectedRoom.id == HARoom.favorites.id {
            return devices.filter(\.isFavorite)
        }
        return devices.filter { $0.room.id == selectedRoom.id }
    }

    // MARK: - Device actions

    /// Entry point for UI taps: asks for confirmation before safety-sensitive actions (unlocking).
    public func requestToggle(_ device: HADeviceItem) {
        if device.domain == .lock && !device.isOn {
            pendingConfirmation = ConfirmationRequest(
                title: L10n.t("Destrancar \(device.name)?", "Unlock \(device.name)?"),
                message: L10n.t("Isso destrancará a fechadura.", "This will unlock the door."),
                confirmTitle: L10n.t("Destrancar", "Unlock"),
                action: { [weak self] in self?.toggleDevice(device.id) }
            )
            return
        }
        toggleDevice(device.id)
    }

    public func toggleDevice(_ deviceId: String) {
        guard let index = deviceIndexById[deviceId] else { return }
        let device = devices[index]

        if device.domain == .script || device.isReadOnly {
            if device.domain == .script {
                dispatchService(domain: "script", service: "turn_on", payload: ["entity_id": deviceId])
            }
            return
        }

        guard let updated = mutateDevice(id: deviceId, mutation: { device in
            device.isOn.toggle()
            if device.isOn && device.domain == .light && device.supportsBrightness && device.brightnessPct < 5 {
                device.brightnessPct = 80
            }
            if device.domain == .switch {
                device.statusSubtitle = L10n.t("Ligado", "On")
            }
        }) else { return }

        let command = updated.powerCommand(turningOn: updated.isOn)
        dispatchService(domain: command.domain, service: command.service, payload: ["entity_id": updated.id])
    }

    public func setRoomPower(_ room: HARoom, on: Bool) {
        let controllable: [HADomain] = [.light, .switch, .fan]
        let targets = devices.filter { device in
            guard controllable.contains(device.domain) else { return false }
            return room.id == HARoom.favorites.id ? device.isFavorite : device.room.id == room.id
        }
        for domain in controllable {
            let ids = targets.filter { $0.domain == domain }.map(\.id)
            guard !ids.isEmpty else { continue }
            for id in ids { mutateDevice(id: id) { $0.isOn = on } }
            dispatchService(domain: domain.rawValue, service: on ? "turn_on" : "turn_off", payload: ["entity_id": ids])
        }
    }

    public func toggleFavorite(_ deviceId: String) {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        let newValue = !device.isFavorite
        favoriteOverrides[deviceId] = newValue
        defaults.set(favoriteOverrides, forKey: Keys.favoriteOverrides)
        mutateDevice(id: deviceId) { $0.isFavorite = newValue }
        showToast(newValue
            ? L10n.t("Adicionado aos favoritos", "Added to favorites")
            : L10n.t("Removido dos favoritos", "Removed from favorites"))
    }

    public func setClimateTemperature(_ temperature: Double, for deviceId: String) {
        guard let updated = mutateDevice(id: deviceId, mutation: { device in
            guard device.domain == .climate else { return }
            device.targetTemperature = min(device.maxTemperature, max(device.minTemperature, temperature.rounded()))
        }), let target = updated.targetTemperature else { return }

        dispatchService(domain: "climate", service: "set_temperature", payload: ["entity_id": deviceId, "temperature": target])
    }

    public func setClimateMode(_ mode: String, for deviceId: String) {
        guard mutateDevice(id: deviceId, mutation: { device in
            guard device.hvacModes.contains(mode) else { return }
            device.hvacMode = mode
            device.isOn = !["off", "unknown", "unavailable"].contains(mode)
        }) != nil else { return }

        dispatchService(domain: "climate", service: "set_hvac_mode", payload: ["entity_id": deviceId, "hvac_mode": mode])
    }

    public func setClimateFan(_ mode: String, for deviceId: String) {
        guard mutateDevice(id: deviceId, mutation: { device in
            guard device.fanModes.contains(mode) else { return }
            device.fanMode = mode
        }) != nil else { return }

        dispatchService(domain: "climate", service: "set_fan_mode", payload: ["entity_id": deviceId, "fan_mode": mode])
    }

    public func setBrightness(for deviceId: String, percentage: Double) {
        let clamped = min(100, max(0, percentage))
        guard mutateDevice(id: deviceId, mutation: { device in
            device.brightnessPct = clamped
            device.isOn = clamped > 1
        }) != nil else { return }

        scheduleDebouncedServiceCall(
            key: deviceId,
            domain: "light",
            service: clamped <= 1 ? "turn_off" : "turn_on",
            payload: clamped <= 1
                ? ["entity_id": deviceId]
                : ["entity_id": deviceId, "brightness_pct": Int(clamped.rounded())]
        )
    }

    public func applyColorPreset(_ preset: HAColorPreset, to deviceId: String) {
        guard mutateDevice(id: deviceId, mutation: { device in
            device.rgbColor = preset.rgb
            device.colorTempKelvin = preset.kelvin
            device.activePresetId = preset.id
            device.isOn = true
            if device.brightnessPct < 5 { device.brightnessPct = 80 }
        }) != nil else { return }

        var payload: [String: Any] = ["entity_id": deviceId]
        if let kelvin = preset.kelvin {
            payload["color_temp_kelvin"] = kelvin
        } else {
            payload["rgb_color"] = preset.rgb.jsonArray
        }
        dispatchService(domain: "light", service: "turn_on", payload: payload)
    }

    public func setCustomRGB(_ rgb: RGBColor, for deviceId: String) {
        guard mutateDevice(id: deviceId, mutation: { device in
            device.rgbColor = rgb
            device.colorTempKelvin = nil
            device.activePresetId = nil
            device.isOn = true
        }) != nil else { return }

        scheduleDebouncedServiceCall(
            key: deviceId,
            domain: "light",
            service: "turn_on",
            payload: ["entity_id": deviceId, "rgb_color": rgb.jsonArray]
        )
    }

    public func setEffect(_ effectName: String, for deviceId: String) {
        guard mutateDevice(id: deviceId, mutation: { device in
            device.activeEffect = effectName
            device.isOn = true
        }) != nil else { return }

        dispatchService(domain: "light", service: "turn_on", payload: ["entity_id": deviceId, "effect": effectName])
    }

    public func activateScene(_ sceneId: String) {
        setActiveScene(sceneId)
        Task { [weak self] in
            guard let self else { return }
            if await self.send(domain: "scene", service: "turn_on", payload: ["entity_id": sceneId]) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await self.refreshStatesSnapshot()
            } else {
                self.setActiveScene(nil)
            }
        }
    }

    public func turnOffAllLights() {
        for index in devices.indices where devices[index].domain == .light {
            devices[index].isOn = false
        }
        setActiveScene(nil)
        if let detailId = selectedDeviceForDetail?.id, let index = deviceIndexById[detailId] {
            selectedDeviceForDetail = devices[index]
        }
        dispatchService(domain: "light", service: "turn_off", payload: ["entity_id": "all"])
    }

    // MARK: - Connection lifecycle

    public func saveSettingsAndConnect(url: String, token: String) {
        serverURLString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.serverURLString = serverURLString
        KeychainHelper.saveToken(accessToken)

        if accessToken.isEmpty {
            cancelConnectionWork()
            client.disconnectWebSocket()
            connectionStatus = .demoMode(host: Self.extractHost(from: serverURLString))
        } else {
            KeychainHelper.isDemoModePreferred = false
            hasLoadedOnce = false
            isLoading = true
            connectToHomeAssistant()
        }
    }

    public func testConnection(url: String, token: String) async -> ConnectionTestResult {
        await client.testConnection(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `silent` keeps the current UI (no "connecting" state or skeleton) – used for background retries.
    public func connectToHomeAssistant(silent: Bool = false) {
        cancelConnectionWork()
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Self.extractHost(from: serverURLString)
        guard !token.isEmpty else {
            connectionStatus = .demoMode(host: host)
            return
        }

        if !silent { connectionStatus = .connecting }
        isLoading = !hasLoadedOnce
        let baseURL = serverURLString

        syncTask = Task { [weak self] in
            await self?.performSync(baseURL: baseURL, token: token, host: host)
        }
    }

    /// Called when the Mac wakes from sleep: the old socket is almost certainly dead.
    public func resyncAfterWake() {
        guard hasCredentials else { return }
        connectToHomeAssistant(silent: true)
    }

    /// Called when the network path becomes usable again.
    public func networkDidBecomeAvailable() {
        guard hasCredentials else { return }
        if case .connected = connectionStatus { return }
        if case .unauthorized = connectionStatus { return }
        connectToHomeAssistant(silent: true)
    }

    public func refreshStatesSnapshot() async {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              let rawStates = await client.fetchStates(baseURL: serverURLString, token: token) else { return }
        applyStates(rawStates)
    }

    /// Exponential backoff: 2, 4, 8, 16 and then 30 seconds.
    public static func reconnectDelay(forAttempt attempt: Int) -> Int {
        min(30, 2 << min(max(attempt, 0), 4))
    }

    #if DEBUG
    public func setDevicesForTesting(_ newDevices: [HADeviceItem]) {
        self.devices = newDevices
    }
    #endif

    public func openHomeAssistantInBrowser() {
        guard let url = URL(string: serverURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Updates

    public func checkForUpdates(userInitiated: Bool, fetcher: (() async -> ReleaseInfo?)? = nil) async {
        let fetch = fetcher ?? { await UpdateChecker.fetchLatestRelease() }
        guard let latest = await fetch() else {
            if userInitiated { updateCheckMessage = L10n.t("Não foi possível verificar atualizações.", "Couldn't check for updates.") }
            return
        }
        if UpdateChecker.isNewer(latest.version, than: AppInfo.version) {
            availableUpdate = latest
            updateCheckMessage = L10n.t("Nova versão disponível: \(latest.version)", "New version available: \(latest.version)")
        } else {
            availableUpdate = nil
            if userInitiated { updateCheckMessage = L10n.t("Você está na versão mais recente.", "You're up to date.") }
        }
    }

    // MARK: - Toasts

    public func showToast(_ text: String, isError: Bool = false) {
        toastTask?.cancel()
        toast = ToastMessage(text: text, isError: isError)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    public func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: - HomeAssistantClientDelegate

    public func clientDidAuthenticate(host: String) {
        reconnectAttempt = 0
        connectionStatus = .connected(host: host)
    }

    public func clientDidFailAuthentication() {
        cancelConnectionWork()
        connectionStatus = .unauthorized
    }

    public func clientDidDisconnect() {
        guard hasCredentials else { return }
        scheduleReconnect()
    }

    public func clientDidReceiveStateUpdate(_ stateObject: [String: Any]) {
        guard let entityId = stateObject["entity_id"] as? String else { return }

        if entityId.hasPrefix("scene.") {
            handleSceneStateUpdate(entityId: entityId, stateObject: stateObject)
            return
        }
        guard applyRemoteUpdate(stateObject, entityId: entityId) else { return }
        invalidateActiveSceneIfNeeded(changedEntityId: entityId)
    }

    // MARK: - Sync internals

    private func performSync(baseURL: String, token: String, host: String) async {
        async let rawAreas = client.fetchAreas(baseURL: baseURL, token: token)
        async let rawStates = client.fetchStates(baseURL: baseURL, token: token)
        let (areas, states) = await (rawAreas, rawStates)
        guard !Task.isCancelled else { return }

        isLoading = false
        guard let states else {
            scheduleReconnect()
            return
        }

        if let areas, !areas.isEmpty {
            let parsed = HAEntityMapper.parseAreasResponse(areas)
            rooms = parsed.rooms
            entityToRoomMap = parsed.entityToRoom
        }
        applyStates(states)
        hasLoadedOnce = true
        reconnectAttempt = 0
        connectionStatus = .connected(host: host)
        client.connectWebSocket(baseURL: baseURL, token: token)
    }

    private func applyStates(_ rawStates: [[String: Any]]) {
        let mapped = HAEntityMapper.mapStates(rawStates, entityToRoom: entityToRoomMap)
        devices = mapped.devices.map { device in
            var copy = device
            if let override = favoriteOverrides[device.id] { copy.isFavorite = override }
            return copy
        }
        applyScenes(mapped.scenes)
        updateRoomList()
        if let detailId = selectedDeviceForDetail?.id {
            selectedDeviceForDetail = devices.first { $0.id == detailId }
        }
    }

    /// Adds the "No room" bucket only when needed and drops stale selections.
    private func updateRoomList() {
        var list = rooms.filter { $0.id != HARoom.unassigned.id }
        if devices.contains(where: { $0.room.id == HARoom.unassigned.id }) {
            list.append(.unassigned)
        }
        if list != rooms { rooms = list }
        if !rooms.contains(where: { $0.id == selectedRoom.id }) { selectedRoom = .favorites }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let host = Self.extractHost(from: serverURLString)
        connectionStatus = .reconnecting(host: host)
        let delay = Self.reconnectDelay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connectToHomeAssistant(silent: true)
        }
    }

    private func cancelConnectionWork() {
        syncTask?.cancel()
        reconnectTask?.cancel()
        syncTask = nil
        reconnectTask = nil
    }

    // MARK: - Scene state

    private func applyScenes(_ newScenes: [HASceneItem]) {
        if activeSceneId == nil, let recent = newScenes.first(where: \.isActive) {
            activeSceneId = recent.id
            sceneActivatedAt = recent.lastActivated ?? Date()
        }
        scenes = newScenes.map { scene in
            var copy = scene
            copy.isActive = (scene.id == activeSceneId)
            return copy
        }
    }

    private func setActiveScene(_ sceneId: String?) {
        activeSceneId = sceneId
        sceneActivatedAt = Date()
        scenes = scenes.map { scene in
            var copy = scene
            copy.isActive = (scene.id == sceneId)
            return copy
        }
    }

    /// A scene activated from another client (phone, automation) updates its entity's state timestamp.
    private func handleSceneStateUpdate(entityId: String, stateObject: [String: Any]) {
        guard scenes.contains(where: { $0.id == entityId }),
              let state = stateObject["state"] as? String,
              HAEntityMapper.parseTimestamp(state) != nil else { return }
        setActiveScene(entityId)
    }

    /// Manually changing a device that belongs to the active scene means the scene no longer applies.
    private func invalidateActiveSceneIfNeeded(changedEntityId: String) {
        guard let activeId = activeSceneId,
              let scene = scenes.first(where: { $0.id == activeId }),
              scene.memberEntityIds.contains(changedEntityId),
              Date().timeIntervalSince(sceneActivatedAt) > sceneGracePeriod else { return }
        setActiveScene(nil)
    }

    // MARK: - Mutation helpers

    /// Local, optimistic update (always applied).
    @discardableResult
    private func mutateDevice(id: String, mutation: (inout HADeviceItem) -> Void) -> HADeviceItem? {
        guard let index = deviceIndexById[id], devices.indices.contains(index) else { return nil }
        mutation(&devices[index])
        let updated = devices[index]
        if selectedDeviceForDetail?.id == id { selectedDeviceForDetail = updated }
        return updated
    }

    /// Remote update: only publishes when something actually changed (Home Assistant is chatty).
    private func applyRemoteUpdate(_ stateObject: [String: Any], entityId: String) -> Bool {
        guard let index = deviceIndexById[entityId], devices.indices.contains(index) else { return false }
        var updated = devices[index]
        HAEntityMapper.applyStateUpdate(stateObject, to: &updated)
        guard updated != devices[index] else { return false }
        devices[index] = updated
        if selectedDeviceForDetail?.id == entityId { selectedDeviceForDetail = updated }
        return true
    }

    private func rebuildIndexMap() {
        var map: [String: Int] = [:]
        map.reserveCapacity(devices.count)
        for (index, item) in devices.enumerated() { map[item.id] = index }
        deviceIndexById = map
    }

    // MARK: - Service calls

    /// Sends a service call; on failure shows a toast and re-syncs to revert optimistic changes.
    @discardableResult
    private func send(domain: String, service: String, payload: [String: Any]) async -> Bool {
        guard hasCredentials else { return true } // demo mode is local only
        let ok = await client.callService(
            baseURL: serverURLString,
            token: accessToken,
            domain: domain,
            service: service,
            payload: payload
        )
        if !ok {
            showToast(L10n.t("Não foi possível enviar o comando", "Couldn't send the command"), isError: true)
            await refreshStatesSnapshot()
        }
        return ok
    }

    private func dispatchService(domain: String, service: String, payload: [String: Any]) {
        Task { await send(domain: domain, service: service, payload: payload) }
    }

    private func scheduleDebouncedServiceCall(key: String, domain: String, service: String, payload: [String: Any]) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.send(domain: domain, service: service, payload: payload)
            self.debounceTasks[key] = nil
        }
    }

    private static func extractHost(from urlString: String) -> String {
        URL(string: urlString)?.host ?? "homeassistant.local"
    }
}
