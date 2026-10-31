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
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }
    @Published public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
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
        self.language = .pt
        self.defaultOpeningRoomId = HARoom.favorites.id
        self.menuBarDisplayMode = .activeLights
        self.requireBiometricsForSensitiveActions = false
        self.confirmTurnOffAll = false
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

    public func applyOpeningRoomPreference() {
        if let target = rooms.first(where: { $0.id == defaultOpeningRoomId }) {
            selectedRoom = target
        }
    }

    public var hasCredentials: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var activeLightsCount: Int {
        devices.reduce(0) { $0 + ($1.domain.countsAsActive && $1.isOn ? 1 : 0) }
    }

    public var totalPowerWatts: Double {
        devices.reduce(0.0) { sum, dev in
            guard dev.isOn, let w = dev.powerWatts else { return sum }
            return sum + Double(w)
        }
    }

    public var primaryTemperatureCelsius: Double? {
        for dev in devices where dev.domain == .sensor {
            if dev.deviceClass == "temperature", let subtitle = dev.statusSubtitle {
                let cleaned = subtitle.split(separator: " ").first ?? ""
                if let temp = Double(cleaned.replacingOccurrences(of: ",", with: ".")) {
                    return temp
                }
            }
        }
        return nil
    }

    public func setPopoverPresented(_ presented: Bool) {
        isPopoverPresented = presented
        if !presented {
            selectedDeviceForDetail = nil
        }
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
            if requireBiometricsForSensitiveActions && BiometricAuthHelper.isBiometricsAvailable {
                Task { @MainActor [weak self] in
                    let success = await BiometricAuthHelper.authenticate(
                        reason: L10n.t("Autentique para destrancar \(device.name)", "Authenticate to unlock \(device.name)")
                    )
                    if success {
                        AuditLogger.shared.log(
                            entityId: device.id,
                            entityName: device.name,
                            action: L10n.t("Destrancado (Biometria)", "Unlocked (Biometric)"),
                            wasBiometric: true
                        )
                        self?.toggleDevice(device.id)
                    } else {
                        self?.showToast(L10n.t("Autenticação biométrica cancelada.", "Biometric authentication cancelled."), isError: true)
                    }
                }
                return
            }

            pendingConfirmation = ConfirmationRequest(
                title: L10n.t("Destrancar \(device.name)?", "Unlock \(device.name)?"),
                message: L10n.t("Isso destrancará a fechadura.", "This will unlock the door."),
                confirmTitle: L10n.t("Destrancar", "Unlock"),
                action: { [weak self] in
                    AuditLogger.shared.log(
                        entityId: device.id,
                        entityName: device.name,
                        action: L10n.t("Destrancado", "Unlocked")
                    )
                    self?.toggleDevice(device.id)
                }
            )
            return
        }
        AuditLogger.shared.log(
            entityId: device.id,
            entityName: device.name,
            action: device.isOn ? L10n.t("Desligado", "Turned Off") : L10n.t("Ligado", "Turned On")
        )
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

    public func requestTurnOffAllLights() {
        if confirmTurnOffAll && activeLightsCount > 0 {
            pendingConfirmation = ConfirmationRequest(
                title: L10n.t("Apagar Todas as Luzes?", "Turn Off All Lights?"),
                message: L10n.t("Isso desligará todas as \(activeLightsCount) lâmpadas conectadas.", "This will switch off all \(activeLightsCount) active lights."),
                confirmTitle: L10n.t("Apagar Tudo", "Turn Off All"),
                action: { [weak self] in
                    self?.turnOffAllLights()
                }
            )
            return
        }
        turnOffAllLights()
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
        updateStatus = .downloading(progress: 0.0, bytesReceived: 0, totalBytes: update.assetSize ?? 0)

        do {
            let stagedURL: URL
            if let customDownloader = downloader {
                stagedURL = try await customDownloader(update) { [weak self] progress, received, total in
                    Task { @MainActor in
                        self?.updateStatus = .downloading(progress: progress, bytesReceived: received, totalBytes: total)
                    }
                }
            } else {
                stagedURL = try await updater.downloadAndStageUpdate(release: update) { [weak self] progress, received, total in
                    Task { @MainActor in
                        self?.updateStatus = .downloading(progress: progress, bytesReceived: received, totalBytes: total)
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
    }

    public func clientDidFailAuthentication() {
        cancelConnectionWork()
        connectionStatus = .unauthorized
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

        for (entityId, stateObject) in lastStateByEntity {
            if applyRemoteUpdate(stateObject, entityId: entityId) {
                invalidateActiveSceneIfNeeded(changedEntityId: entityId)
            }
        }
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
