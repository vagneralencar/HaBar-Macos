import Foundation
import SwiftUI

public enum HAConnectionStatus: Equatable {
    case connected(host: String)
    case connecting
    case demoMode(host: String)
    case error(String)

    public var labelText: String {
        switch self {
        case .connected(let host):
            return "\(host) • Conectado"
        case .demoMode(let host):
            return "\(host) • Modo Local"
        case .connecting:
            return "Conectando ao Home Assistant..."
        case .error(let msg):
            return msg
        }
    }

    public var isHealthy: Bool {
        switch self {
        case .connected, .demoMode:
            return true
        case .connecting, .error:
            return false
        }
    }
}

@MainActor
public final class HomeAssistantStore: ObservableObject, HomeAssistantClientDelegate {
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
    public let isScreenshotPreview: Bool

    private let client: HomeAssistantClient
    private var deviceIndexById: [String: Int] = [:]
    private var entityToRoomMap: [String: HARoom] = [:]
    private var debounceTask: Task<Void, Never>?

    public init(client: HomeAssistantClient = HomeAssistantClient()) {
        self.client = client
        self.isScreenshotPreview = false
        let savedURL = KeychainHelper.serverURLString
        let savedToken = KeychainHelper.loadToken()
        self.serverURLString = savedURL
        self.accessToken = savedToken

        rebuildIndexMap()
        self.client.delegate = self

        let hostDisplay = Self.extractHost(from: savedURL)
        if !savedToken.isEmpty {
            connectToHomeAssistant()
        } else {
            self.connectionStatus = .demoMode(host: hostDisplay)
        }
    }

    public static func makeScreenshotDemoStore() -> HomeAssistantStore {
        let store = HomeAssistantStore(isScreenshotPreview: true)
        return store
    }

    private init(isScreenshotPreview: Bool) {
        self.client = HomeAssistantClient()
        self.isScreenshotPreview = isScreenshotPreview
        self.serverURLString = "http://homeassistant.local:8123"
        self.accessToken = ""
        self.connectionStatus = .connected(host: "homeassistant.local")
        var demoScenes = HASceneItem.defaultMockupScenes
        if !demoScenes.isEmpty {
            demoScenes[0].isActive = true
        }
        self.scenes = demoScenes
        self.devices = HADeviceItem.defaultMockupDevices
        rebuildIndexMap()
    }

    // MARK: - Computed High-Performance Queries

    public var activeLightsCount: Int {
        devices.reduce(0) { count, item in
            count + (item.domain != .script && item.isOn ? 1 : 0)
        }
    }

    public func hasActiveDevice(in room: HARoom) -> Bool {
        if room.id == HARoom.favorites.id {
            return devices.contains { $0.isFavorite && $0.domain != .script && $0.isOn }
        }
        return devices.contains { $0.room.id == room.id && $0.domain != .script && $0.isOn }
    }

    public var filteredScenes: [HASceneItem] {
        scenes
    }

    public var filteredDevices: [HADeviceItem] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return devices.filter { item in
            let matchesRoom = (selectedRoom == .favorites) ? item.isFavorite : (item.room.id == selectedRoom.id)
            guard matchesRoom else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(trimmedQuery) ||
                   item.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    // MARK: - DRY State Mutation & Device Actions

    public func toggleDevice(_ deviceId: String) {
        if let index = deviceIndexById[deviceId], devices[index].domain == .script {
            // Running a script is a momentary action, never an AC state toggle.
            dispatchService(domain: "script", service: "turn_on", payload: ["entity_id": deviceId])
            return
        }
        guard let updated = mutateDevice(id: deviceId, mutation: { device in
            device.isOn.toggle()
            if device.isOn && device.domain == .light && device.supportsBrightness && device.brightnessPct < 5 {
                device.brightnessPct = 80
            }
            if device.domain == .switch {
                device.statusSubtitle = device.isOn ? "Ligado" : "Desligado"
            }
        }) else { return }

        dispatchService(
            domain: updated.domain.rawValue,
            service: updated.isOn ? "turn_on" : "turn_off",
            payload: ["entity_id": updated.id]
        )
    }

    public func setClimateTemperature(_ temperature: Double, for deviceId: String) {
        guard let updated = mutateDevice(id: deviceId, mutation: { device in
            guard device.domain == .climate else { return }
            let value = min(device.maxTemperature, max(device.minTemperature, temperature.rounded()))
            device.targetTemperature = value
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

        dispatchService(
            domain: "light",
            service: "turn_on",
            payload: ["entity_id": deviceId, "effect": effectName]
        )
    }

    public func activateScene(_ sceneId: String) {
        for index in scenes.indices {
            scenes[index].isActive = (scenes[index].id == sceneId)
        }

        let baseURL = serverURLString
        let token = accessToken
        Task {
            await client.callService(
                baseURL: baseURL,
                token: token,
                domain: "scene",
                service: "turn_on",
                payload: ["entity_id": sceneId]
            )
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshStatesSnapshot()
        }
    }

    public func turnOffAllLights() {
        for index in devices.indices where devices[index].domain == .light {
            devices[index].isOn = false
        }
        for index in scenes.indices {
            scenes[index].isActive = false
        }
        if let detailId = selectedDeviceForDetail?.id, let idx = deviceIndexById[detailId] {
            selectedDeviceForDetail = devices[idx]
        }

        dispatchService(domain: "light", service: "turn_off", payload: ["entity_id": "all"])
    }

    // MARK: - Connection Management

    public func saveSettingsAndConnect(url: String, token: String) {
        serverURLString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.serverURLString = serverURLString
        KeychainHelper.saveToken(accessToken)

        if accessToken.isEmpty {
            client.disconnectWebSocket()
            connectionStatus = .demoMode(host: Self.extractHost(from: serverURLString))
        } else {
            KeychainHelper.isDemoModePreferred = false
            connectToHomeAssistant()
        }
    }

    public func connectToHomeAssistant() {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Self.extractHost(from: serverURLString)
        guard !trimmedToken.isEmpty else {
            connectionStatus = .demoMode(host: host)
            return
        }

        connectionStatus = .connecting
        let baseURL = serverURLString

        Task {
            async let rawAreasTask = client.fetchAreas(baseURL: baseURL, token: trimmedToken)
            async let rawStatesTask = client.fetchStates(baseURL: baseURL, token: trimmedToken)

            let (rawAreas, rawStates) = await (rawAreasTask, rawStatesTask)

            if let rawAreas, !rawAreas.isEmpty {
                let parsedAreas = HAEntityMapper.parseAreasResponse(rawAreas)
                self.rooms = parsedAreas.rooms
                self.entityToRoomMap = parsedAreas.entityToRoom
            }

            if let rawStates {
                let mapped = HAEntityMapper.mapStates(rawStates, entityToRoom: self.entityToRoomMap)
                if !mapped.devices.isEmpty { self.devices = mapped.devices }
                if !mapped.scenes.isEmpty { self.scenes = mapped.scenes }
                self.connectionStatus = .connected(host: host)
            } else {
                self.connectionStatus = .demoMode(host: host)
            }

            client.connectWebSocket(baseURL: baseURL, token: trimmedToken)
        }
    }

    public func refreshStatesSnapshot() async {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty,
              let rawStates = await client.fetchStates(baseURL: serverURLString, token: trimmedToken) else { return }
        let mapped = HAEntityMapper.mapStates(rawStates, entityToRoom: entityToRoomMap)
        if !mapped.devices.isEmpty { self.devices = mapped.devices }
    }

    public func openHomeAssistantInBrowser() {
        guard let url = URL(string: serverURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - HomeAssistantClientDelegate

    public func clientDidAuthenticate(host: String) {
        connectionStatus = .connected(host: host)
    }

    public func clientDidReceiveStateUpdate(_ stateObject: [String: Any]) {
        guard let entityId = stateObject["entity_id"] as? String else { return }
        _ = mutateDevice(id: entityId) { item in
            HAEntityMapper.applyStateUpdate(stateObject, to: &item)
        }
    }

    // MARK: - Private DRY Helpers

    @discardableResult
    private func mutateDevice(id: String, mutation: (inout HADeviceItem) -> Void) -> HADeviceItem? {
        guard let idx = deviceIndexById[id], devices.indices.contains(idx) else { return nil }
        mutation(&devices[idx])
        let updated = devices[idx]
        if selectedDeviceForDetail?.id == id {
            selectedDeviceForDetail = updated
        }
        return updated
    }

    private func rebuildIndexMap() {
        var map: [String: Int] = [:]
        map.reserveCapacity(devices.count)
        for (index, item) in devices.enumerated() {
            map[item.id] = index
        }
        deviceIndexById = map
    }

    private func dispatchService(domain: String, service: String, payload: [String: Any]) {
        let baseURL = serverURLString
        let token = accessToken
        Task {
            await client.callService(baseURL: baseURL, token: token, domain: domain, service: service, payload: payload)
        }
    }

    private func scheduleDebouncedServiceCall(domain: String, service: String, payload: [String: Any]) {
        debounceTask?.cancel()
        let baseURL = serverURLString
        let token = accessToken
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await client.callService(baseURL: baseURL, token: token, domain: domain, service: service, payload: payload)
        }
    }

    private static func extractHost(from urlString: String) -> String {
        URL(string: urlString)?.host ?? "homeassistant.local"
    }
}
