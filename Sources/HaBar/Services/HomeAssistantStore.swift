import Foundation
import SwiftUI

public enum HAConnectionStatus: Equatable {
    case connected(host: String)
    case connecting
    case reconnecting(host: String)
    case unauthorized
    case forbidden
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
        case .forbidden:
            return L10n.t("Conta sem permissão", "Account lacks permission")
        case .unauthorized:
            return L10n.t("Token inválido ou expirado", "Invalid or expired token")
        }
    }

    public var isHealthy: Bool {
        switch self {
        case .connected, .demoMode: return true
        case .connecting, .reconnecting, .unauthorized, .forbidden: return false
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
    @Published public private(set) var devices: [HADeviceItem] = HADeviceItem.defaultMockupDevices
    @Published public var selectedRoom: HARoom = .favorites
    @Published public var searchQuery: String = ""
    @Published public var isSearchVisible: Bool = false
    @Published public var selectedDeviceForDetail: HADeviceItem? = nil
    @Published public var isShowingSettings: Bool = false

    @Published public var serverURLString: String
    public var accessToken: String
    @Published public private(set) var connectionStatus: HAConnectionStatus = .connecting
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var toast: ToastMessage?
    @Published public var pendingConfirmation: ConfirmationRequest?
    @Published public private(set) var availableUpdate: ReleaseInfo?
    @Published public private(set) var updateCheckMessage: String?
    @Published public var updateStatus: AppUpdateStatus = .idle
    @Published public var isDismissedUpdateBanner: Bool = false
    @Published public var stagedAppURL: URL? = nil

    @Published public var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    @Published public var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    @Published public var themeMode: AppThemeMode {
        didSet { if !isScreenshotPreview { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) } }
    }
    @Published public var language: AppLanguage {
        didSet {
            if !isScreenshotPreview { defaults.set(language.rawValue, forKey: Keys.language) }
            L10n.forcedLanguage = language == .system ? nil : language.rawValue
        }
    }
    @Published public var defaultOpeningRoomId: String {
        didSet { defaults.set(defaultOpeningRoomId, forKey: Keys.defaultOpeningRoomId) }
    }
    @Published public var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: Keys.menuBarDisplayMode) }
    }
    @Published public var requireBiometricsForSensitiveActions: Bool {
        didSet { defaults.set(requireBiometricsForSensitiveActions, forKey: Keys.requireBiometricsForSensitiveActions) }
    }
    @Published public var confirmTurnOffAll: Bool {
        didSet { defaults.set(confirmTurnOffAll, forKey: Keys.confirmTurnOffAll) }
    }
    @Published public private(set) var isPopoverPresented: Bool = false

    @Published public private(set) var commandStatuses: [String: DeviceCommandStatus] = [:]
    @Published public var temperatureSensorId: String = "" { didSet { defaults.set(temperatureSensorId, forKey: "habar.temperatureSensor") } }
    @Published public var powerSensorId: String = "" { didSet { defaults.set(powerSensorId, forKey: "habar.powerSensor") } }
    @Published public private(set) var lastSyncAt: Date?
    public let isScreenshotPreview: Bool

    // MARK: - Private state

    private enum Keys {
        static let favoriteOverrides = "habar.favoriteOverrides"
        static let hotKeyEnabled = "habar.hotKeyEnabled"
        static let autoCheckUpdates = "habar.autoCheckUpdates"
        static let themeMode = "habar.themeMode"
        static let language = "habar.language"
        static let defaultOpeningRoomId = "habar.defaultOpeningRoomId"
        static let menuBarDisplayMode = "habar.menuBarDisplayMode"
        static let requireBiometricsForSensitiveActions = "habar.requireBiometrics"
        static let confirmTurnOffAll = "habar.confirmTurnOffAll"
    }

    private let client: HomeAssistantAPI
    private let defaults: UserDefaults
    private var deviceIndexById: [String: Int] = [:]
    private var entityToRoomMap: [String: HARoom] = [:]
    private var favoriteOverrides: [String: Bool]
    private let commands = CommandCoordinator()
    private var confirmedDevices: [String: HADeviceItem] = [:]
    private var commandIds: [String: UUID] = [:]
    private var lastCommands: [String: CommandCoordinator.Command] = [:]
    private var confirmationTasks: [String: Task<Void, Never>] = [:]
    private var sessionEpoch = 0
    private var climateTemperatureUnit = "°C"
    private var authenticationInProgress = Set<String>()
    private let scripts = KeychainHelper.scriptCommands
    private let ignoredSuffixes = KeychainHelper.ignoredEntitySuffixes
    private let scenePrefixes = KeychainHelper.stripScenePrefixes
    private var syncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var hasLoadedOnce = false
    private var activeSceneId: String?
    private var sceneActivatedAt = Date.distantPast

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

        let savedLang = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init) ?? .system
        self.language = savedLang
        L10n.forcedLanguage = savedLang == .system ? nil : savedLang.rawValue

        let savedDefaultRoom = defaults.string(forKey: Keys.defaultOpeningRoomId) ?? HARoom.favorites.id
        self.defaultOpeningRoomId = savedDefaultRoom

        let savedDisplayMode = defaults.string(forKey: Keys.menuBarDisplayMode).flatMap(MenuBarDisplayMode.init) ?? .activeLights
        self.menuBarDisplayMode = savedDisplayMode
        self.requireBiometricsForSensitiveActions = defaults.object(forKey: Keys.requireBiometricsForSensitiveActions) as? Bool ?? true
        self.confirmTurnOffAll = defaults.bool(forKey: Keys.confirmTurnOffAll)

        let savedURL = KeychainHelper.serverURLString
        let savedToken = KeychainHelper.loadToken()
        self.serverURLString = savedURL
        self.accessToken = savedToken

        self.client.delegate = self
        self.temperatureSensorId = defaults.string(forKey: "habar.temperatureSensor") ?? ""
        self.powerSensorId = defaults.string(forKey: "habar.powerSensor") ?? ""
        commands.execute = { [weak self] command in await self?.execute(command) }

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
        confirmedDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        if let error = KeychainHelper.lastError { showToast(error, isError: true) }
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
        self.language = .pt
        self.defaultOpeningRoomId = HARoom.favorites.id
        self.menuBarDisplayMode = .activeLights
        self.requireBiometricsForSensitiveActions = false
        self.confirmTurnOffAll = false
        self.serverURLString = "http://homeassistant.local:8123"
        self.accessToken = ""
        self.connectionStatus = .demoMode(host: "homeassistant.local")
        self.activeSceneId = HASceneItem.defaultMockupScenes.first?.id
        self.scenes = HASceneItem.defaultMockupScenes.map { scene in
            var copy = scene
            copy.isActive = (scene.id == activeSceneId)
            return copy
        }
        self.devices = HADeviceItem.defaultMockupDevices
        commands.execute = { [weak self] command in await self?.execute(command) }
        rebuildIndexMap()
        confirmedDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    }

    // MARK: - Derived queries

    public func applyOpeningRoomPreference() {
        if let target = rooms.first(where: { $0.id == defaultOpeningRoomId }) {
            selectedRoom = target
        }
    }

    public var hasCredentials: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var activeLightsCount: Int {
        let lightIds = Set(devices.filter { $0.domain == .light }.map(\.id))
        let groups = Set(devices.filter { $0.domain == .light && $0.memberEntityIds.contains(where: lightIds.contains) }.map(\.id))
        return devices.filter { $0.domain == .light && $0.availability == .available && $0.isOn && !groups.contains($0.id) }.count
    }
    public var activeDevicesCount: Int { devices.filter { $0.domain.countsAsActive && $0.isOn && $0.availability == .available }.count }
    public var powerReadingWatts: Double? {
        let candidates = devices.filter { $0.deviceClass == "power" }
        let chosen = powerSensorId.isEmpty ? (candidates.count == 1 ? candidates.first : nil) : candidates.first { $0.id == powerSensorId }
        return chosen?.measuredWatts
    }
    public var totalPowerWatts: Double { powerReadingWatts ?? 0 }
    public var primaryTemperatureCelsius: Double? {
        let candidates = devices.filter { $0.deviceClass == "temperature" }
        let chosen = temperatureSensorId.isEmpty ? (candidates.count == 1 ? candidates.first : nil) : candidates.first { $0.id == temperatureSensorId }
        return chosen?.temperatureCelsius
    }

    public func setPopoverPresented(_ presented: Bool) {
        isPopoverPresented = presented
        if !presented {
            selectedDeviceForDetail = nil
            pendingConfirmation = nil
        }
    }

    public func hasActiveDevice(in room: HARoom) -> Bool {
        devices.contains { device in
            guard device.domain.countsAsActive, device.isOn, device.availability == .available else { return false }
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

    public func device(id: String) -> HADeviceItem? {
        guard let index = deviceIndexById[id], devices.indices.contains(index) else { return nil }
        return devices[index]
    }

    public func requestToggle(_ supplied: HADeviceItem) {
        guard let device = device(id: supplied.id), device.canToggle else { return }
        let turningOn = !device.isOn
        let sensitive = (device.domain == .lock || (device.domain == .cover && ["garage", "gate", "door"].contains(device.deviceClass ?? ""))) && turningOn
        guard sensitive else { setPower(device.id, on: turningOn); return }
        let epoch = sessionEpoch
        if requireBiometricsForSensitiveActions {
            guard authenticationInProgress.insert(device.id).inserted else { return }
            Task { [weak self] in
                let success = await BiometricAuthHelper.authenticate(reason: L10n.t("Autorize abrir \(device.name)", "Authorize opening \(device.name)"))
                guard let self, epoch == self.sessionEpoch else { return }
                self.authenticationInProgress.remove(device.id)
                if success { self.setPower(device.id, on: true, authenticated: true) }
                else { self.showToast(L10n.t("Autenticação necessária. Nenhum comando enviado.", "Authentication required. No command sent."), isError: true) }
            }
        } else {
            pendingConfirmation = ConfirmationRequest(
                title: L10n.t("Abrir \(device.name)?", "Open \(device.name)?"),
                message: L10n.t("Esta ação permite acesso físico.", "This action permits physical access."),
                confirmTitle: L10n.t("Abrir", "Open"), action: { [weak self] in
                    guard let self, self.sessionEpoch == epoch else { return }
                    self.setPower(device.id, on: true)
                })
        }
    }

    public func toggleDevice(_ id: String) {
        guard let item = device(id: id) else { return }
        requestToggle(item)
    }

    private func setPower(_ id: String, on: Bool, authenticated: Bool = false) {
        guard let item = device(id: id), item.canToggle else { return }
        if item.domain == .climate, let mode = on ? item.hvacModes.first(where: { $0 != "off" }) : item.hvacModes.first(where: { $0 == "off" }) {
            setClimateMode(mode, for: id); return
        }
        let command = item.powerCommand(turningOn: on)
        // Physical access controls keep their last confirmed state until HA reports a change.
        if item.domain != .lock && item.domain != .cover && item.domain != .script {
            mutateDevice(id: id) { $0.isOn = on }
        }
        enqueue(id: id, domain: command.domain, service: command.service, payload: ["entity_id": id], authenticated: authenticated)
    }

    public func setRoomPower(_ room: HARoom, on: Bool) {
        let targets = devices.filter { [.light, .switch, .fan].contains($0.domain) && $0.canControl && (room.id == HARoom.favorites.id ? $0.isFavorite : $0.room.id == room.id) }
        for target in targets { setPower(target.id, on: on) }
    }

    public func toggleFavorite(_ deviceId: String) {
        guard let device = device(id: deviceId) else { return }
        let newValue = !device.isFavorite
        favoriteOverrides[deviceId] = newValue
        defaults.set(favoriteOverrides, forKey: Keys.favoriteOverrides)
        mutateDevice(id: deviceId) { $0.isFavorite = newValue }
        confirmedDevices[deviceId]?.isFavorite = newValue
    }

    public func setClimateTemperature(_ temperature: Double, for id: String) {
        guard let item = device(id: id), item.domain == .climate, item.canControl, temperature.isFinite else { return }
        let rounded = (temperature / item.temperatureStep).rounded() * item.temperatureStep
        let target = min(item.maxTemperature, max(item.minTemperature, rounded))
        mutateDevice(id: id) { $0.targetTemperature = target }
        enqueue(id: id, domain: "climate", service: "set_temperature", payload: ["entity_id": id, "temperature": target], debounce: true)
    }

    public func setClimateMode(_ mode: String, for id: String) {
        guard let item = device(id: id), item.canControl, item.hvacModes.contains(mode) else { return }
        mutateDevice(id: id) { $0.hvacMode = mode; $0.isOn = mode != "off" }
        enqueue(id: id, domain: "climate", service: "set_hvac_mode", payload: ["entity_id": id, "hvac_mode": mode])
    }

    public func setClimateFan(_ mode: String, for id: String) {
        guard let item = device(id: id), item.canControl, item.fanModes.contains(mode) else { return }
        mutateDevice(id: id) { $0.fanMode = mode }
        enqueue(id: id, domain: "climate", service: "set_fan_mode", payload: ["entity_id": id, "fan_mode": mode])
    }

    public func setBrightness(for id: String, percentage: Double) {
        guard let item = device(id: id), item.canControl, item.supportsBrightness, percentage.isFinite else { return }
        let value = min(100, max(0, percentage)).rounded()
        mutateDevice(id: id) { $0.brightnessPct = value; $0.isOn = value > 0 }
        enqueue(id: id, domain: "light", service: value == 0 ? "turn_off" : "turn_on", payload: value == 0 ? ["entity_id": id] : ["entity_id": id, "brightness_pct": Int(value)], debounce: value > 0)
    }

    public func setColorTemperature(_ kelvin: Int, for id: String) {
        guard let item = device(id: id), item.canControl, item.supportsColorTemperature else { return }
        let value = min(item.maxKelvin, max(item.minKelvin, kelvin))
        mutateDevice(id: id) { $0.colorTempKelvin = value; $0.activePresetId = nil; $0.isOn = true }
        enqueue(id: id, domain: "light", service: "turn_on", payload: ["entity_id": id, "color_temp_kelvin": value], debounce: true)
    }

    public func applyColorPreset(_ preset: HAColorPreset, to id: String) {
        if let kelvin = preset.kelvin { setColorTemperature(kelvin, for: id) }
        else { setCustomRGB(preset.rgb, for: id) }
    }

    public func setCustomRGB(_ rgb: RGBColor, for id: String) {
        guard let item = device(id: id), item.canControl, item.supportsRGB else { return }
        mutateDevice(id: id) { $0.rgbColor = rgb; $0.colorTempKelvin = nil; $0.activePresetId = nil; $0.isOn = true }
        enqueue(id: id, domain: "light", service: "turn_on", payload: ["entity_id": id, "rgb_color": rgb.jsonArray], debounce: true)
    }

    public func setEffect(_ effectName: String, for id: String) {
        guard let item = device(id: id), item.canControl, item.availableEffects.contains(effectName) else { return }
        mutateDevice(id: id) { $0.activeEffect = effectName; $0.isOn = true }
        enqueue(id: id, domain: "light", service: "turn_on", payload: ["entity_id": id, "effect": effectName])
    }

    public func activateScene(_ sceneId: String) {
        guard scenes.contains(where: { $0.id == sceneId }) else { return }
        enqueue(id: sceneId, domain: "scene", service: "turn_on", payload: ["entity_id": sceneId])
    }

    public func requestTurnOffAllLights() {
        if confirmTurnOffAll && activeLightsCount > 0 {
            let epoch = sessionEpoch
            pendingConfirmation = ConfirmationRequest(
                title: L10n.t("Apagar todas as luzes?", "Turn off all lights?"),
                message: L10n.t("Aplica-se a todas as luzes disponíveis, em todos os cômodos.", "Applies to all available lights in every room."),
                confirmTitle: L10n.t("Apagar luzes", "Turn off lights"), action: { [weak self] in
                    guard let self, epoch == self.sessionEpoch else { return }
                    self.turnOffAllLights()
                })
        } else { turnOffAllLights() }
    }

    public func turnOffAllLights() {
        for item in devices where item.domain == .light && item.canControl { setPower(item.id, on: false) }
    }

    public func retryCommand(for id: String) {
        guard let command = lastCommands[id] else { return }
        let epoch = sessionEpoch
        pendingConfirmation = ConfirmationRequest(title: L10n.t("Enviar novamente?", "Send again?"),
            message: L10n.t("O comando anterior pode ter sido executado. Confira o dispositivo antes de continuar.", "The previous command may have executed. Check the device before continuing."),
            confirmTitle: L10n.t("Enviar", "Send"), action: { [weak self] in
                guard let self, epoch == self.sessionEpoch else { return }
                if command.domain == "lock" || command.domain == "cover" {
                    self.showToast(L10n.t("Use o controle do dispositivo para autorizar uma nova ação.", "Use the device control to authorize a new action.")); return
                }
                self.enqueue(id: id, domain: command.domain, service: command.service, payload: command.payload)
            })
    }

    // MARK: - Connection lifecycle

    @discardableResult public func saveSettingsAndConnect(url: String, token: String) -> Bool {
        do {
            guard let normalized = HomeAssistantURL.normalized(url) else { throw HAAPIError.invalidURL }
            try KeychainHelper.saveConnection(url: normalized, token: token)
            sessionEpoch += 1
            cancelConnectionWork(); client.resetSession(); commands.reset()
            confirmationTasks.values.forEach { $0.cancel() }; confirmationTasks.removeAll()
            pendingStateUpdates.removeAll(); batchFlushTask?.cancel(); batchFlushTask = nil
            commandStatuses = [:]; commandIds = [:]; lastCommands = [:]; authenticationInProgress = []
            pendingConfirmation = nil; selectedDeviceForDetail = nil
            rooms = [.favorites]; devices = []; scenes = []; confirmedDevices = [:]; entityToRoomMap = [:]
            rebuildIndexMap(); activeSceneId = nil; lastSyncAt = nil
            serverURLString = normalized
            accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            hasLoadedOnce = false
            if accessToken.isEmpty {
                isLoading = false
                connectionStatus = .demoMode(host: Self.extractHost(from: normalized))
            } else { connectToHomeAssistant() }
            return true
        } catch { showToast(error.localizedDescription, isError: true); return false }
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

        client.disconnectWebSocket()
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
        if connectionStatus == .unauthorized || connectionStatus == .forbidden { return }
        connectToHomeAssistant(silent: true)
    }

    public func refreshStatesSnapshot() async {
        let epoch = sessionEpoch
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            let rawStates = try await client.fetchStates(baseURL: serverURLString, token: token)
            guard epoch == sessionEpoch, token == accessToken, !Task.isCancelled else { return }
            applyStates(rawStates)
        } catch {
            guard epoch == sessionEpoch, !Task.isCancelled else { return }
            if error as? HAAPIError == .unauthorized { clientDidFailAuthentication() }
            else if error as? HAAPIError == .forbidden { failAccess(.forbidden) }
        }
    }

    /// Exponential backoff: 2, 4, 8, 16 and then 30 seconds.
    public static func reconnectDelay(forAttempt attempt: Int) -> Int {
        min(30, 2 << min(max(attempt, 0), 4))
    }

    #if DEBUG
    public func setDevicesForTesting(_ newDevices: [HADeviceItem]) {
        self.devices = newDevices
        rebuildIndexMap()
        confirmedDevices = Dictionary(uniqueKeysWithValues: newDevices.map { ($0.id, $0) })
    }
    #endif

    public func openHomeAssistantInBrowser() {
        guard let url = URL(string: serverURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Updates

    public func checkForUpdates(userInitiated: Bool, fetcher: (() async -> ReleaseInfo?)? = nil) async {
        switch updateStatus { case .downloading, .readyToInstall, .installing, .checking: return; default: break }
        updateStatus = .checking
        let fetch = fetcher ?? { await UpdateChecker.fetchLatestRelease() }
        guard let latest = await fetch() else {
            updateStatus = .idle
            if userInitiated { updateCheckMessage = L10n.t("Não foi possível verificar atualizações.", "Couldn't check for updates.") }
            return
        }
        if UpdateChecker.isNewer(latest.version, than: AppInfo.version) {
            availableUpdate = latest
            updateStatus = .available(latest)
            updateCheckMessage = L10n.t("Nova versão disponível: \(latest.version)", "New version available: \(latest.version)")
        } else {
            availableUpdate = nil
            updateStatus = .upToDate
            if userInitiated { updateCheckMessage = L10n.t("Você está na versão mais recente.", "You're up to date.") }
        }
    }

    public func startInAppUpdate(
        updater: AppUpdater = .shared,
        downloader: ((ReleaseInfo, @escaping @Sendable (Double, Int64, Int64) -> Void) async throws -> URL)? = nil
    ) async {
        guard let update = availableUpdate else { return }
        switch updateStatus { case .downloading, .installing: return; default: break }
        isDismissedUpdateBanner = false
        updateStatus = .downloading(progress: 0.0, bytesReceived: 0, totalBytes: update.assetSize ?? 0)

        do {
            let stagedURL: URL
            if let customDownloader = downloader {
                stagedURL = try await customDownloader(update) { [weak self] progress, received, total in
                    Task { @MainActor in
                        guard let self, case .downloading = self.updateStatus else { return }
                        self.updateStatus = .downloading(progress: progress, bytesReceived: received, totalBytes: total)
                    }
                }
            } else {
                stagedURL = try await updater.downloadAndStageUpdate(release: update) { [weak self] progress, received, total in
                    Task { @MainActor in
                        guard let self, case .downloading = self.updateStatus else { return }
                        self.updateStatus = .downloading(progress: progress, bytesReceived: received, totalBytes: total)
                    }
                }
            }
            self.stagedAppURL = stagedURL
            self.updateStatus = .readyToInstall(update, stagedAppURL: stagedURL)
            self.showToast(L10n.t("Atualização pronta para instalar!", "Update ready to install!"))
        } catch {
            self.updateStatus = .failed(error.localizedDescription)
            self.showToast(error.localizedDescription, isError: true)
        }
    }

    public func applyUpdateAndRestart(updater: AppUpdater = .shared, installer: ((URL) throws -> Void)? = nil) {
        guard case .readyToInstall(_, let stagedURL) = updateStatus else { return }
        updateStatus = .installing
        do {
            if let customInstaller = installer {
                try customInstaller(stagedURL)
            } else {
                try updater.installAndRelaunch(stagedAppURL: stagedURL)
            }
        } catch {
            updateStatus = .failed(error.localizedDescription)
            showToast(error.localizedDescription, isError: true)
        }
    }

    public func dismissUpdateBanner() {
        isDismissedUpdateBanner = true
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
        // Close the gap between the initial REST snapshot and the event subscription.
        Task { [weak self] in await self?.refreshStatesSnapshot() }
    }

    public func clientDidFailAuthentication() { failAccess(.unauthorized) }

    private func failAccess(_ error: HAAPIError) {
        sessionEpoch += 1
        cancelConnectionWork()
        client.resetSession()
        commands.reset()
        confirmationTasks.values.forEach { $0.cancel() }
        confirmationTasks.removeAll(); commandIds.removeAll()
        pendingConfirmation = nil
        for id in commandStatuses.keys {
            if let confirmed = confirmedDevices[id] { mutateDevice(id: id) { $0 = confirmed } }
            commandStatuses[id] = .failed(error.localizedDescription)
        }
        connectionStatus = error == .forbidden ? .forbidden : .unauthorized
    }

    public func clientDidDisconnect() {
        guard hasCredentials else { return }
        scheduleReconnect()
    }

    private var pendingStateUpdates: [[String: Any]] = []
    private var batchFlushTask: Task<Void, Never>?

    public func clientDidReceiveStateUpdate(_ stateObject: [String: Any]) {
        pendingStateUpdates.append(stateObject)
        if pendingStateUpdates.count >= 40 {
            flushPendingStateUpdates()
        } else if batchFlushTask == nil {
            batchFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 35_000_000)
                guard !Task.isCancelled else { return }
                self?.flushPendingStateUpdates()
            }
        }
    }

    public func flushPendingStateUpdates() {
        batchFlushTask?.cancel()
        batchFlushTask = nil
        guard !pendingStateUpdates.isEmpty else { return }

        let updates = pendingStateUpdates
        pendingStateUpdates.removeAll()

        var lastStateByEntity: [String: [String: Any]] = [:]
        for update in updates {
            guard let entityId = update["entity_id"] as? String else { continue }
            if entityId.hasPrefix("scene.") {
                handleSceneStateUpdate(entityId: entityId, stateObject: update)
            } else {
                lastStateByEntity[entityId] = update
            }
        }

        var next = devices
        for (id, state) in lastStateByEntity {
            if let index = deviceIndexById[id] {
                var updated = next[index]
                HAEntityMapper.applyStateUpdate(state, to: &updated)
                confirmedDevices[id] = updated
                next[index] = updated
                reconcileCommand(id: id, with: updated)
            } else {
                let mapped = HAEntityMapper.mapStates([state], entityToRoom: entityToRoomMap, scriptCommands: scripts, ignoredSuffixes: ignoredSuffixes, stripScenePrefixes: scenePrefixes, temperatureUnit: climateTemperatureUnit, rooms: rooms)
                for var added in mapped.devices {
                    added.isFavorite = favoriteOverrides[added.id] ?? added.isFavorite
                    next.append(added); confirmedDevices[added.id] = added
                }
            }
        }
        if next != devices {
            let membershipChanged = next.count != devices.count
            devices = next
            if membershipChanged { rebuildIndexMap(); updateRoomList() }
        }
        if let id = selectedDeviceForDetail?.id { selectedDeviceForDetail = device(id: id) }
        lastSyncAt = Date()
    }

    public func clientDidRemoveEntity(_ entityId: String) {
        pendingStateUpdates.removeAll { $0["entity_id"] as? String == entityId }
        devices.removeAll { $0.id == entityId }; scenes.removeAll { $0.id == entityId }
        confirmedDevices.removeValue(forKey: entityId)
        commandStatuses.removeValue(forKey: entityId); commandIds.removeValue(forKey: entityId)
        confirmationTasks.removeValue(forKey: entityId)?.cancel()
        rebuildIndexMap(); updateRoomList()
        if selectedDeviceForDetail?.id == entityId { selectedDeviceForDetail = nil }
    }

    // MARK: - Sync internals

    private func performSync(baseURL: String, token: String, host: String) async {
        let epoch = sessionEpoch
        do {
            async let unit = try client.fetchTemperatureUnit(baseURL: baseURL, token: token)
            async let rawAreas = try? client.fetchAreas(baseURL: baseURL, token: token)
            let states = try await client.fetchStates(baseURL: baseURL, token: token)
            let areas = await rawAreas
            let temperatureUnit = try await unit
            guard !Task.isCancelled, epoch == sessionEpoch else { return }
            isLoading = false
            climateTemperatureUnit = temperatureUnit
            if let areas {
                let parsed = HAEntityMapper.parseAreasResponse(areas)
                rooms = parsed.rooms; entityToRoomMap = parsed.entityToRoom
            }
            applyStates(states)
            hasLoadedOnce = true
            client.connectWebSocket(baseURL: baseURL, token: token)
        } catch {
            guard !Task.isCancelled, epoch == sessionEpoch else { return }
            isLoading = false
            if error as? HAAPIError == .unauthorized { clientDidFailAuthentication() }
            else if error as? HAAPIError == .forbidden { failAccess(.forbidden) }
            else { scheduleReconnect() }
        }
    }

    private func applyStates(_ rawStates: [[String: Any]]) {
        let mapped = HAEntityMapper.mapStates(rawStates, entityToRoom: entityToRoomMap, scriptCommands: scripts, ignoredSuffixes: ignoredSuffixes, stripScenePrefixes: scenePrefixes, temperatureUnit: climateTemperatureUnit, rooms: rooms)
        devices = mapped.devices.map { device in
            var copy = device
            if let existing = confirmedDevices[device.id], let old = existing.updatedAt, let fresh = device.updatedAt, old > fresh { copy = existing }
            if let override = favoriteOverrides[device.id] { copy.isFavorite = override }
            return copy
        }
        rebuildIndexMap()
        confirmedDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        for item in devices { reconcileCommand(id: item.id, with: item) }
        lastSyncAt = Date()
        applyScenes(mapped.scenes)
        updateRoomList()
        if let detailId = selectedDeviceForDetail?.id {
            selectedDeviceForDetail = devices.first { $0.id == detailId }
        }
    }

    /// Adds the "No room" bucket only when needed and drops stale selections.
    private func updateRoomList() {
        var list = rooms.filter { $0.id != HARoom.unassigned.id }
        if !list.contains(where: { $0.id == HARoom.favorites.id }) { list.insert(.favorites, at: 0) }
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
        let latest = newScenes.filter { $0.lastActivated != nil }.max { ($0.lastActivated ?? .distantPast) < ($1.lastActivated ?? .distantPast) }
        activeSceneId = latest?.id
        scenes = newScenes.map { scene in
            var copy = scene; copy.isActive = scene.id == activeSceneId; return copy
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
        guard let state = stateObject["state"] as? String, let date = HAEntityMapper.parseTimestamp(state) else { return }
        if let index = scenes.firstIndex(where: { $0.id == entityId }) {
            if let previous = scenes[index].lastActivated, date < previous { return }
            scenes[index].lastActivated = date
        }
        else {
            scenes += HAEntityMapper.mapStates([stateObject], entityToRoom: entityToRoomMap, scriptCommands: scripts, ignoredSuffixes: ignoredSuffixes, stripScenePrefixes: scenePrefixes, temperatureUnit: climateTemperatureUnit, rooms: rooms).scenes
        }
        applyScenes(scenes)
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

    private func rebuildIndexMap() {
        var map: [String: Int] = [:]
        map.reserveCapacity(devices.count)
        for (index, item) in devices.enumerated() { map[item.id] = index }
        deviceIndexById = map
    }

    // MARK: - Service calls

    private func enqueue(id: String, domain: String, service: String, payload: [String: Any], debounce: Bool = false, authenticated: Bool = false) {
        if connectionStatus == .unauthorized || connectionStatus == .forbidden {
            if let confirmed = confirmedDevices[id] { mutateDevice(id: id) { $0 = confirmed } }
            showToast((connectionStatus == .forbidden ? HAAPIError.forbidden : .unauthorized).localizedDescription, isError: true)
            return
        }
        confirmationTasks.removeValue(forKey: id)?.cancel()
        commandStatuses[id] = .sending
        commandIds[id] = commands.submit(entityId: id, domain: domain, service: service, payload: payload, debounce: debounce, authenticated: authenticated)
    }

    private func execute(_ command: CommandCoordinator.Command) async {
        let epoch = sessionEpoch
        let id = command.entityId
        guard commandIds[id] == command.id else { return }
        lastCommands[id] = command
        audit(command, outcome: "requested")
        guard hasCredentials else {
            confirmedDevices[id] = device(id: id)
            commandStatuses.removeValue(forKey: id); audit(command, outcome: "demo"); return
        }
        do {
            try await client.callService(baseURL: serverURLString, token: accessToken, domain: command.domain, service: command.service, payload: command.payload)
            guard epoch == sessionEpoch, !Task.isCancelled else { return }
            audit(command, outcome: "accepted")
            guard commandIds[id] == command.id else { return }
            if command.domain == "scene" || command.domain == "script" {
                commandStatuses.removeValue(forKey: id)
                if command.domain == "scene" { setActiveScene(id) }
                return
            }
            commandStatuses[id] = .awaitingConfirmation
            if let confirmed = confirmedDevices[id] { reconcileCommand(id: id, with: confirmed) }
            guard commandStatuses[id] != nil else { return }
            confirmationTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.sessionEpoch == epoch, self.commandIds[id] == command.id else { return }
                await self.refreshStatesSnapshot()
                guard !Task.isCancelled, self.sessionEpoch == epoch, self.commandIds[id] == command.id else { return }
                if self.commandStatuses[id] != nil { self.fail(command, error: HAAPIError.uncertain) }
            }
        } catch {
            guard epoch == sessionEpoch, !Task.isCancelled else { return }
            if commandIds[id] == command.id { fail(command, error: error) }
            if error as? HAAPIError == .unauthorized { clientDidFailAuthentication() }
        }
    }

    private func fail(_ command: CommandCoordinator.Command, error: Error) {
        if let confirmed = confirmedDevices[command.entityId] {
            mutateDevice(id: confirmed.id) { $0 = confirmed }
        }
        commandStatuses[command.entityId] = .failed(error.localizedDescription)
        audit(command, outcome: "unconfirmed")
        showToast(error.localizedDescription, isError: true)
    }

    private func reconcileCommand(id: String, with item: HADeviceItem) {
        guard let command = lastCommands[id], commandIds[id] == command.id,
              commandStatuses[id] == .awaitingConfirmation, item.availability == .available, !item.isTransitioning else { return }
        let p = command.payload
        let matches: Bool
        switch command.service {
        case "turn_off", "lock", "close_cover": matches = !item.isOn
        case "set_temperature": matches = item.targetTemperature == p["temperature"] as? Double
        case "set_hvac_mode": matches = item.hvacMode == p["hvac_mode"] as? String
        case "set_fan_mode": matches = item.fanMode == p["fan_mode"] as? String
        default:
            let brightness = (p["brightness_pct"] as? Int).map { abs(item.brightnessPct - Double($0)) <= 1 } ?? true
            let rgb = (p["rgb_color"] as? [Int]).map { $0 == item.rgbColor.jsonArray } ?? true
            let kelvin = (p["color_temp_kelvin"] as? Int).map { abs((item.colorTempKelvin ?? 0) - $0) <= 50 } ?? true
            let effect = (p["effect"] as? String).map { $0 == item.activeEffect } ?? true
            matches = item.isOn && brightness && rgb && kelvin && effect
        }
        if matches {
            commandStatuses.removeValue(forKey: id)
            confirmationTasks.removeValue(forKey: id)?.cancel()
            audit(command, outcome: "confirmed")
        }
    }

    private func audit(_ command: CommandCoordinator.Command, outcome: String) {
        guard !KeychainHelper.isIsolatedForTesting && !isScreenshotPreview else { return }
        AuditLogger.shared.log(entityId: command.entityId, entityName: device(id: command.entityId)?.name ?? command.entityId,
            action: "\(command.domain).\(command.service)", wasBiometric: false, outcome: outcome, authenticated: command.authenticated)
    }

    private static func extractHost(from urlString: String) -> String {
        URL(string: urlString)?.host ?? "homeassistant.local"
    }
}
