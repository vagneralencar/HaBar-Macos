import Foundation
import SwiftUI

public struct RGBColor: Equatable, Hashable, Sendable, Codable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = min(255, max(0, red))
        self.green = min(255, max(0, green))
        self.blue = min(255, max(0, blue))
    }

    public var swiftUIColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }

    public var jsonArray: [Int] {
        [red, green, blue]
    }

    public static let warmWhite = RGBColor(246, 178, 68)
    public static let softWarm = RGBColor(255, 226, 154)
    public static let ceilingWarm = RGBColor(255, 214, 120)
    public static let daylight = RGBColor(216, 238, 255)
    public static let sunset = RGBColor(255, 118, 46)
    public static let cyberpunk = RGBColor(168, 56, 255)
    public static let ocean = RGBColor(28, 209, 255)
    public static let climateCyan = RGBColor(50, 173, 230)
    public static let switchGreen = RGBColor(48, 209, 88)
}

public enum HADomain: String, Codable, CaseIterable, Sendable {
    case light
    case scene
    case script
    case climate
    case `switch`
    case cover
    case fan
    case lock
    case mediaPlayer = "media_player"
    case sensor
    case binarySensor = "binary_sensor"
    case other

    /// Sensors only report; they have nothing to toggle.
    public var isReadOnly: Bool {
        self == .sensor || self == .binarySensor
    }

    /// Whether an "on" device of this kind should count toward the "N devices on" badge.
    public var countsAsActive: Bool {
        switch self {
        case .light, .switch, .fan, .climate: return true
        default: return false
        }
    }
}

public struct HARoom: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var shortDisplayName: String {
        let lower = name.lowercased()
        if lower == "sala de jantar" { return "Sala Jantar" }
        if lower == "sala de estar" { return "Sala Estar" }
        if lower == "sala de tv" { return "Sala TV" }
        if lower == "área de serviço" || lower == "area de servico" { return "Serviço" }
        if lower == "living room" { return "Living" }
        return name
    }

    public var iconSystemName: String {
        let lower = (id + " " + name).lowercased()
        if id == HARoom.favorites.id { return "star.fill" }
        if id == HARoom.unassigned.id { return "tray.fill" }
        if lower.contains("jantar") || lower.contains("dining") { return "fork.knife" }
        if lower.contains("tv") || lower.contains("estar") || lower.contains("living") { return "tv.fill" }
        if lower.contains("escritorio") || lower.contains("escritório") || lower.contains("office") { return "desktopcomputer" }
        if lower.contains("quarto") || lower.contains("bedroom") { return "bed.double.fill" }
        if lower.contains("cozinha") || lower.contains("kitchen") { return "flame.fill" }
        if lower.contains("serviço") || lower.contains("servico") || lower.contains("laundry") { return "washer.fill" }
        if lower.contains("garagem") || lower.contains("garage") { return "car.fill" }
        if lower.contains("banheiro") || lower.contains("bath") { return "shower.fill" }
        return "house.fill"
    }

    public static var favorites: HARoom { HARoom(id: "__favorites__", name: L10n.t("Favoritos", "Favorites")) }
    public static var unassigned: HARoom { HARoom(id: "__unassigned__", name: L10n.t("Sem cômodo", "No room")) }

    // Demo-mode rooms (only used before a server is configured).
    public static let salaJantar = HARoom(id: "sala_de_estar", name: "Sala de jantar")
    public static let salaTV = HARoom(id: "sala_de_tv", name: "Sala de TV")
    public static let escritorio = HARoom(id: "escritorio", name: "Escritório")
    public static let quarto = HARoom(id: "quarto", name: "Quarto")
    public static let cozinha = HARoom(id: "cozinha", name: "Cozinha")
    public static let areaServico = HARoom(id: "area_de_servico", name: "Área de serviço")

    public static var defaultRooms: [HARoom] {
        [.favorites, .salaJantar, .salaTV, .escritorio, .quarto, .cozinha, .areaServico]
    }
}

public struct HAColorPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let rgb: RGBColor
    public let kelvin: Int?

    public var swiftUIColor: Color { rgb.swiftUIColor }

    public static var defaultPresets: [HAColorPreset] {
        [
            HAColorPreset(id: "warm_2700", name: L10n.t("Branco\nQuente", "Warm\nWhite"), subtitle: "2700K", rgb: .warmWhite, kelvin: 2700),
            HAColorPreset(id: "daylight_5000", name: L10n.t("Luz do Dia", "Daylight"), subtitle: "5000K", rgb: .daylight, kelvin: 5000),
            HAColorPreset(id: "sunset", name: L10n.t("Pôr do Sol", "Sunset"), subtitle: nil, rgb: .sunset, kelvin: nil),
            HAColorPreset(id: "cyberpunk", name: "Cyberpunk", subtitle: nil, rgb: .cyberpunk, kelvin: nil),
            HAColorPreset(id: "ocean", name: L10n.t("Oceano", "Ocean"), subtitle: nil, rgb: .ocean, kelvin: nil)
        ]
    }
}

public struct HASceneItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var iconSystemName: String
    public var isActive: Bool
    /// Entities the scene controls (from the scene's `entity_id` attribute).
    public var memberEntityIds: [String]
    /// When the scene was last activated (the scene entity's state is that timestamp).
    public var lastActivated: Date?

    public init(
        id: String,
        name: String,
        iconSystemName: String,
        isActive: Bool = false,
        memberEntityIds: [String] = [],
        lastActivated: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.isActive = isActive
        self.memberEntityIds = memberEntityIds
        self.lastActivated = lastActivated
    }
}

/// A momentary script exposed as a button (typically an IR remote command).
public struct ScriptCommand: Equatable, Sendable {
    public let entityId: String
    public let name: String
    public let icon: String
    public let roomId: String?

    public init(entityId: String, name: String, icon: String, roomId: String? = nil) {
        self.entityId = entityId
        self.name = name
        self.icon = icon
        self.roomId = roomId
    }
}

public struct HADeviceItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var domain: HADomain
    public var room: HARoom
    public var isFavorite: Bool
    public var isOn: Bool
    public var supportsBrightness: Bool
    public var supportsColor: Bool
    public var brightnessPct: Double
    public var rgbColor: RGBColor
    public var colorTempKelvin: Int?
    public var activePresetId: String?
    public var activeEffect: String
    public var availableEffects: [String]
    public var iconSystemName: String
    public var statusSubtitle: String?
    public var powerWatts: Int?

    public var targetTemperature: Double? = nil
    public var minTemperature: Double = 16
    public var maxTemperature: Double = 30
    public var hvacMode: String? = nil
    public var hvacModes: [String] = []
    public var fanMode: String? = nil
    public var fanModes: [String] = []
    public var isAssumedState: Bool = false
    public var deviceClass: String? = nil
    public var coverPosition: Int? = nil

    public var isReadOnly: Bool { domain.isReadOnly }

    public static func modeTitle(_ mode: String) -> String {
        let titles = [
            "off": L10n.t("Desligado", "Off"),
            "cool": L10n.t("Ar frio", "Cool"),
            "heat": L10n.t("Ar quente", "Heat"),
            "auto": "Auto",
            "fan_only": L10n.t("Ventilar", "Fan only"),
            "dry": L10n.t("Desumidificar", "Dry")
        ]
        return titles[mode] ?? mode
    }

    public static func fanTitle(_ mode: String) -> String {
        let titles = [
            "auto": "Auto",
            "low": L10n.t("Fraco", "Low"),
            "medium": L10n.t("Médio", "Medium"),
            "high": L10n.t("Forte", "High")
        ]
        return titles[mode] ?? mode
    }

    public var accentColor: Color {
        guard isOn else { return Color.white.opacity(0.35) }
        switch domain {
        case .light:
            return rgbColor.swiftUIColor
        case .climate:
            return AppTheme.cyanClimate
        case .switch, .fan:
            return AppTheme.amberAccent
        case .lock:
            return AppTheme.dangerRed
        default:
            return AppTheme.greenOnline
        }
    }

    public var formattedStatusLine: String {
        let baseLine: String
        switch domain {
        case .climate:
            let label = Self.modeTitle(hvacMode ?? L10n.t("Sem estado", "No state"))
            baseLine = label + (isAssumedState ? L10n.t(" · estimado", " · estimated") : "")
        case .script:
            return isOn ? L10n.t("Enviando comando…", "Sending command…") : L10n.t("Toque para enviar", "Tap to send")
        case .lock:
            return isOn ? L10n.t("Destrancada", "Unlocked") : L10n.t("Trancada", "Locked")
        case .cover:
            if let position = coverPosition, isOn { return L10n.t("Aberta • \(position)%", "Open • \(position)%") }
            return isOn ? L10n.t("Aberta", "Open") : L10n.t("Fechada", "Closed")
        case .sensor, .binarySensor:
            return statusSubtitle ?? "—"
        case .mediaPlayer:
            baseLine = statusSubtitle ?? (isOn ? L10n.t("Ligado", "On") : L10n.t("Desligado", "Off"))
        case .light where supportsBrightness:
            baseLine = isOn ? L10n.t("Ligado • \(Int(brightnessPct.rounded()))%", "On • \(Int(brightnessPct.rounded()))%") : L10n.t("Desligado", "Off")
        default:
            if let custom = statusSubtitle { baseLine = isOn ? custom : L10n.t("Desligado", "Off") }
            else { baseLine = isOn ? L10n.t("Ligado", "On") : L10n.t("Desligado", "Off") }
        }

        if isOn, let watts = powerWatts, watts > 0 {
            return "\(baseLine) • \(watts) W"
        }
        return baseLine
    }

    /// Service that turns this device on/off (or its closest equivalent, e.g. unlock/lock).
    public func powerCommand(turningOn: Bool) -> (domain: String, service: String) {
        switch domain {
        case .cover: return ("cover", turningOn ? "open_cover" : "close_cover")
        case .lock: return ("lock", turningOn ? "unlock" : "lock")
        case .script: return ("script", "turn_on")
        default: return (domain.rawValue, turningOn ? "turn_on" : "turn_off")
        }
    }
}

extension HADeviceItem {
    /// Convenience initializer for simple on/off style devices.
    public init(id: String, name: String, domain: HADomain, room: HARoom, icon: String, isOn: Bool = false) {
        self.init(
            id: id, name: name, domain: domain, room: room,
            isFavorite: true, isOn: isOn,
            supportsBrightness: false, supportsColor: false,
            brightnessPct: 100, rgbColor: .warmWhite, colorTempKelvin: nil,
            activePresetId: nil, activeEffect: "", availableEffects: [],
            iconSystemName: icon, statusSubtitle: nil, powerWatts: nil
        )
    }
}

// MARK: - Pure Mapper for Home Assistant JSON States & Areas

public enum HAEntityMapper {
    private static let readOnlySensorClasses: Set<String> = ["temperature", "humidity", "power"]
    private static let binarySensorClasses: Set<String> = ["door", "window", "opening", "garage_door", "motion", "occupancy"]
    private static let offStates: Set<String> = ["off", "unknown", "unavailable"]

    public static func parseAreasResponse(_ rawArray: [[String: Any]]) -> (rooms: [HARoom], entityToRoom: [String: HARoom]) {
        var rooms: [HARoom] = [.favorites]
        var entityMap: [String: HARoom] = [:]

        for item in rawArray {
            guard let areaId = item["id"] as? String,
                  let areaName = item["name"] as? String else { continue }
            let room = HARoom(id: areaId, name: areaName)
            rooms.append(room)

            if let entities = item["entities"] as? [String] {
                for eid in entities {
                    entityMap[eid] = room
                }
            }
        }
        return (rooms, entityMap)
    }

    public static func mapStates(
        _ states: [[String: Any]],
        entityToRoom: [String: HARoom],
        scriptCommands: [ScriptCommand] = KeychainHelper.scriptCommands,
        ignoredSuffixes: [String] = KeychainHelper.ignoredEntitySuffixes,
        stripScenePrefixes: [String] = KeychainHelper.stripScenePrefixes,
        now: Date = Date()
    ) -> (devices: [HADeviceItem], scenes: [HASceneItem]) {
        var devices: [HADeviceItem] = []
        var scenes: [HASceneItem] = []
        let commandsById = Dictionary(scriptCommands.map { ($0.entityId, $0) }, uniquingKeysWith: { first, _ in first })

        for stateObj in states {
            guard let entityId = stateObj["entity_id"] as? String,
                  let state = stateObj["state"] as? String else { continue }

            if state == "unavailable" || ignoredSuffixes.contains(where: { entityId.hasSuffix($0) }) {
                continue
            }

            let attrs = stateObj["attributes"] as? [String: Any] ?? [:]

            if entityId.hasPrefix("scene.") {
                scenes.append(makeScene(entityId: entityId, state: state, attrs: attrs, stripPrefixes: stripScenePrefixes, now: now))
                continue
            }

            let room = resolveRoom(
                entityId: entityId,
                name: friendlyName(entityId: entityId, attrs: attrs),
                entityToRoom: entityToRoom,
                scriptRoomId: commandsById[entityId]?.roomId
            )
            guard var device = makeDevice(entityId: entityId, state: state, attrs: attrs, room: room, scriptCommand: commandsById[entityId]) else {
                continue
            }

            // Read-only sensors flood the UI unless the user placed them in a room.
            if device.isReadOnly {
                guard entityToRoom[entityId] != nil else { continue }
                device.isFavorite = false
            }
            devices.append(device)
        }

        // A native climate entity makes IR helper scripts for the same room redundant.
        let climateRoomIds = Set(devices.filter { $0.domain == .climate }.map { $0.room.id })
        devices.removeAll { $0.domain == .script && climateRoomIds.contains($0.room.id) }

        scenes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        devices.sort(by: deviceOrdering)
        return (devices, scenes)
    }

    /// Re-derives a device from a fresh Home Assistant state while keeping local-only fields.
    public static func applyStateUpdate(_ stateObj: [String: Any], to item: inout HADeviceItem) {
        guard let state = stateObj["state"] as? String else { return }
        let attrs = stateObj["attributes"] as? [String: Any] ?? [:]

        if item.domain == .script {
            item.isOn = (state == "on")
            return
        }
        guard var fresh = makeDevice(entityId: item.id, state: state, attrs: attrs, room: item.room, scriptCommand: nil) else { return }

        fresh.isFavorite = item.isFavorite
        fresh.activePresetId = item.activePresetId
        fresh.name = item.name
        // Off lights report no brightness/color: remember the last values so turning them on restores them.
        if fresh.domain == .light && !fresh.isOn {
            fresh.brightnessPct = item.brightnessPct
            fresh.rgbColor = item.rgbColor
            fresh.colorTempKelvin = item.colorTempKelvin
        }
        item = fresh
    }

    // MARK: - Builders

    private static func makeScene(entityId: String, state: String, attrs: [String: Any], stripPrefixes: [String], now: Date) -> HASceneItem {
        let friendlyName = friendlyName(entityId: entityId, attrs: attrs)
        let activated = parseTimestamp(state)
        let isRecent = activated.map { now.timeIntervalSince($0) < 120 && now.timeIntervalSince($0) >= 0 } ?? false
        return HASceneItem(
            id: entityId,
            name: cleanSceneName(friendlyName, stripPrefixes: stripPrefixes),
            iconSystemName: iconForScene(id: entityId, name: friendlyName),
            isActive: isRecent,
            memberEntityIds: attrs["entity_id"] as? [String] ?? [],
            lastActivated: activated
        )
    }

    static func makeDevice(
        entityId: String,
        state: String,
        attrs: [String: Any],
        room: HARoom,
        scriptCommand: ScriptCommand?
    ) -> HADeviceItem? {
        let name = friendlyName(entityId: entityId, attrs: attrs)
        let domainPrefix = entityId.split(separator: ".").first.map(String.init) ?? ""

        switch domainPrefix {
        case "light":
            return makeLight(entityId: entityId, name: name, state: state, attrs: attrs, room: room)
        case "switch":
            var device = HADeviceItem(id: entityId, name: name, domain: .switch, room: room, icon: iconForSwitch(name: name), isOn: state == "on")
            device.statusSubtitle = L10n.t("Ligado", "On")
            device.powerWatts = extractPowerWatts(from: attrs)
            return device
        case "fan":
            var device = HADeviceItem(id: entityId, name: name, domain: .fan, room: room, icon: "fan.fill", isOn: state == "on")
            device.powerWatts = extractPowerWatts(from: attrs)
            return device
        case "climate":
            return makeClimate(entityId: entityId, name: name, state: state, attrs: attrs, room: room)
        case "cover":
            var device = HADeviceItem(id: entityId, name: name, domain: .cover, room: room, icon: "blinds.horizontal.open", isOn: state != "closed")
            device.coverPosition = attrs["current_position"] as? Int
            return device
        case "lock":
            let unlocked = ["unlocked", "open", "unlocking"].contains(state)
            return HADeviceItem(id: entityId, name: name, domain: .lock, room: room, icon: unlocked ? "lock.open.fill" : "lock.fill", isOn: unlocked)
        case "media_player":
            var device = HADeviceItem(id: entityId, name: name, domain: .mediaPlayer, room: room, icon: "play.rectangle.fill", isOn: !offStates.contains(state) && state != "standby")
            device.statusSubtitle = mediaStatus(state)
            return device
        case "sensor":
            guard let deviceClass = attrs["device_class"] as? String, readOnlySensorClasses.contains(deviceClass) else { return nil }
            var device = HADeviceItem(id: entityId, name: name, domain: .sensor, room: room, icon: sensorIcon(deviceClass))
            device.deviceClass = deviceClass
            let unit = (attrs["unit_of_measurement"] as? String) ?? ""
            device.statusSubtitle = unit.isEmpty ? state : "\(state) \(unit)"
            return device
        case "binary_sensor":
            guard let deviceClass = attrs["device_class"] as? String, binarySensorClasses.contains(deviceClass) else { return nil }
            let isOn = state == "on"
            var device = HADeviceItem(id: entityId, name: name, domain: .binarySensor, room: room, icon: binarySensorIcon(deviceClass, isOn: isOn), isOn: isOn)
            device.deviceClass = deviceClass
            device.statusSubtitle = binarySensorStatus(deviceClass, isOn: isOn)
            return device
        case "script":
            guard let command = scriptCommand else { return nil }
            return HADeviceItem(id: entityId, name: command.name, domain: .script, room: room, icon: command.icon, isOn: state == "on")
        default:
            return nil
        }
    }

    private static func makeLight(entityId: String, name: String, state: String, attrs: [String: Any], room: HARoom) -> HADeviceItem {
        let isOn = (state == "on")
        let colorModes = (attrs["supported_color_modes"] as? [String]) ?? []
        let supportsColor = colorModes.contains { ["hs", "rgb", "rgbw", "rgbww", "color_temp", "xy"].contains($0) }
        let supportsBrightness = supportsColor || colorModes.contains("brightness")

        let rawBrightness = (attrs["brightness"] as? Double) ?? (attrs["brightness"] as? Int).map(Double.init) ?? (isOn ? 255.0 : 0.0)
        let pct = min(100, max(0, (rawBrightness / 255.0) * 100.0))
        let effects = (attrs["effect_list"] as? [String]) ?? []
        let isGroup = (attrs["entity_id"] as? [String]) != nil
        let isBacklight = entityId.contains("luz_de_fundo") || entityId.contains("backlight")

        return HADeviceItem(
            id: entityId,
            name: name,
            domain: .light,
            room: room,
            isFavorite: !isBacklight && (isGroup || supportsColor),
            isOn: isOn,
            supportsBrightness: supportsBrightness,
            supportsColor: supportsColor,
            brightnessPct: isOn ? max(pct, 5) : 0,
            rgbColor: extractRGB(from: attrs) ?? .warmWhite,
            colorTempKelvin: (attrs["color_temp_kelvin"] as? Double).map { Int($0) } ?? (attrs["color_temp_kelvin"] as? Int),
            activePresetId: nil,
            activeEffect: (attrs["effect"] as? String) ?? "off",
            availableEffects: effects,
            iconSystemName: iconForLight(id: entityId, name: name),
            statusSubtitle: nil,
            powerWatts: extractPowerWatts(from: attrs)
        )
    }

    private static func makeClimate(entityId: String, name: String, state: String, attrs: [String: Any], room: HARoom) -> HADeviceItem {
        var climate = HADeviceItem(
            id: entityId, name: name, domain: .climate, room: room,
            isFavorite: true, isOn: !offStates.contains(state),
            supportsBrightness: false, supportsColor: false,
            brightnessPct: 0, rgbColor: .climateCyan, colorTempKelvin: nil,
            activePresetId: nil, activeEffect: "", availableEffects: [],
            iconSystemName: "air.conditioner.horizontal.fill", statusSubtitle: nil, powerWatts: nil
        )
        climate.targetTemperature = attrs["temperature"] as? Double
        climate.minTemperature = attrs["min_temp"] as? Double ?? 16
        climate.maxTemperature = attrs["max_temp"] as? Double ?? 30
        climate.hvacMode = state
        climate.hvacModes = attrs["hvac_modes"] as? [String] ?? []
        climate.fanMode = attrs["fan_mode"] as? String
        climate.fanModes = attrs["fan_modes"] as? [String] ?? []
        climate.isAssumedState = attrs["assumed_state"] as? Bool ?? false
        return climate
    }

    // MARK: - Ordering & parsing helpers

    private static func deviceOrdering(_ a: HADeviceItem, _ b: HADeviceItem) -> Bool {
        let aBacklight = a.id.contains("luz_de_fundo") || a.id.contains("backlight")
        let bBacklight = b.id.contains("luz_de_fundo") || b.id.contains("backlight")
        if aBacklight != bBacklight { return !aBacklight }
        if a.isReadOnly != b.isReadOnly { return !a.isReadOnly }
        if a.supportsBrightness != b.supportsBrightness { return a.supportsBrightness }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    public static func inferRoom(from text: String) -> HARoom {
        let lower = text.lowercased()
        if lower.contains("escritorio") || lower.contains("escritório") || lower.contains("office") {
            return .escritorio
        }
        if lower.contains("quarto") || lower.contains("abajur") || lower.contains("bedroom") {
            return .quarto
        }
        if lower.contains("cozinha") || lower.contains("kitchen") {
            return .cozinha
        }
        if lower.contains("serviço") || lower.contains("servico") || lower.contains("laundry") {
            return .areaServico
        }
        if lower.contains("tv") {
            return .salaTV
        }
        if lower.contains("jantar") || lower.contains("dining") {
            return .salaJantar
        }
        return .unassigned
    }

    private static func resolveRoom(entityId: String, name: String, entityToRoom: [String: HARoom], scriptRoomId: String?) -> HARoom {
        if let room = entityToRoom[entityId] { return room }
        if let scriptRoomId {
            if let room = Set(entityToRoom.values).first(where: { $0.id == scriptRoomId }) ?? HARoom.defaultRooms.first(where: { $0.id == scriptRoomId }) {
                return room
            }
        }
        let inferred = inferRoom(from: "\(entityId) \(name)")
        if inferred != .unassigned {
            return inferred
        }
        return .unassigned
    }

    private static func friendlyName(entityId: String, attrs: [String: Any]) -> String {
        ((attrs["friendly_name"] as? String) ?? entityId).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func cleanSceneName(_ raw: String, stripPrefixes: [String]) -> String {
        for prefix in stripPrefixes where raw.lowercased().hasPrefix(prefix.lowercased()) {
            return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private static func extractPowerWatts(from attrs: [String: Any]) -> Int? {
        if let watts = (attrs["current_consumption"] as? Double)
            ?? (attrs["power"] as? Double)
            ?? (attrs["current_power_w"] as? Double)
            ?? (attrs["power_consumption"] as? Double) {
            return Int(watts.rounded())
        }
        if let watts = (attrs["current_consumption"] as? Int)
            ?? (attrs["power"] as? Int)
            ?? (attrs["current_power_w"] as? Int)
            ?? (attrs["power_consumption"] as? Int) {
            return watts
        }
        return nil
    }

    private static func extractRGB(from attrs: [String: Any]) -> RGBColor? {
        if let arr = attrs["rgb_color"] as? [Int], arr.count == 3 {
            return RGBColor(arr[0], arr[1], arr[2])
        }
        if let kelvin = (attrs["color_temp_kelvin"] as? Double) ?? (attrs["color_temp_kelvin"] as? Int).map(Double.init) {
            return kelvin >= 4500 ? .daylight : .warmWhite
        }
        return nil
    }

    // MARK: - Presentation helpers

    private static func mediaStatus(_ state: String) -> String? {
        switch state {
        case "playing": return L10n.t("Reproduzindo", "Playing")
        case "paused": return L10n.t("Pausado", "Paused")
        case "idle": return L10n.t("Ocioso", "Idle")
        default: return nil
        }
    }

    private static func sensorIcon(_ deviceClass: String) -> String {
        switch deviceClass {
        case "humidity": return "humidity.fill"
        case "power": return "bolt.fill"
        default: return "thermometer.medium"
        }
    }

    private static func binarySensorIcon(_ deviceClass: String, isOn: Bool) -> String {
        switch deviceClass {
        case "motion", "occupancy": return isOn ? "figure.walk.motion" : "figure.stand"
        case "window": return isOn ? "window.casement" : "window.casement.closed"
        case "garage_door": return "door.garage.closed"
        default: return isOn ? "door.left.hand.open" : "door.left.hand.closed"
        }
    }

    private static func binarySensorStatus(_ deviceClass: String, isOn: Bool) -> String {
        switch deviceClass {
        case "motion", "occupancy":
            return isOn ? L10n.t("Movimento", "Motion") : L10n.t("Sem movimento", "Clear")
        default:
            return isOn ? L10n.t("Aberto", "Open") : L10n.t("Fechado", "Closed")
        }
    }

    private static func iconForLight(id: String, name: String) -> String {
        let lower = (id + " " + name).lowercased()
        if lower.contains("abajur") || lower.contains("lamp") { return "lamp.table.fill" }
        if lower.contains("spot") { return "light.recessed.fill" }
        if lower.contains("escritorio") || lower.contains("escritório") || lower.contains("desk") || lower.contains("office") { return "lamp.desk.fill" }
        if lower.contains("quarto") || lower.contains("bedroom") { return "bed.double.fill" }
        if lower.contains("luz_de_fundo") { return "switch.2" }
        return "lightbulb.fill"
    }

    private static func iconForSwitch(name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("tv") { return "tv.fill" }
        if lower.contains("cozinha") || lower.contains("luz") || lower.contains("light") || lower.contains("spot") { return "lightbulb.2.fill" }
        return "poweroutlet.type.b.fill"
    }

    private static func iconForScene(id: String, name: String) -> String {
        let lower = (id + " " + name).lowercased()
        if lower.contains("cinema") || lower.contains("movie") { return "film.stack.fill" }
        if lower.contains("jantar") || lower.contains("dinner") { return "fork.knife" }
        if lower.contains("trabalho") || lower.contains("work") { return "desktopcomputer" }
        if lower.contains("relax") { return "sofa.fill" }
        if lower.contains("boa_noite") || lower.contains("boa noite") || lower.contains("night") { return "moon.stars.fill" }
        if lower.contains("cheguei") || lower.contains("arrive") || lower.contains("home") { return "house.fill" }
        if lower.contains("sair") || lower.contains("leave") || lower.contains("away") { return "lock.fill" }
        if lower.contains("desligar") || lower.contains("off") { return "lightbulb.slash.fill" }
        return "sparkles"
    }
}

// MARK: - Generic demo entities (shown until a server is configured)

extension HADeviceItem {
    public static var defaultMockupDevices: [HADeviceItem] {
        [
            HADeviceItem(
                id: "light.spots_sala_jantar",
                name: L10n.t("Spots — Sala de Jantar", "Dining Room Spots"),
                domain: .light, room: .salaJantar, isFavorite: true, isOn: true,
                supportsBrightness: true, supportsColor: true, brightnessPct: 80,
                rgbColor: .warmWhite, colorTempKelvin: 2700, activePresetId: "warm_2700",
                activeEffect: "off", availableEffects: ["Scene", "Music", "off"],
                iconSystemName: "light.recessed.fill", statusSubtitle: nil, powerWatts: nil
            ),
            HADeviceItem(
                id: "light.escritorio",
                name: L10n.t("Luz Escritório", "Office Light"),
                domain: .light, room: .escritorio, isFavorite: true, isOn: true,
                supportsBrightness: true, supportsColor: true, brightnessPct: 100,
                rgbColor: .daylight, colorTempKelvin: 5000, activePresetId: "daylight_5000",
                activeEffect: "off", availableEffects: ["Scene", "Music", "off"],
                iconSystemName: "lamp.desk.fill", statusSubtitle: nil, powerWatts: nil
            ),
            HADeviceItem(
                id: "switch.sala_tv",
                name: L10n.t("Luz da Sala de TV", "TV Room Light"),
                domain: .switch, room: .salaTV, icon: "tv.fill"
            ),
            HADeviceItem(
                id: "light.luz_quarto",
                name: L10n.t("Luz do Quarto", "Bedroom Light"),
                domain: .light, room: .quarto, isFavorite: true, isOn: false,
                supportsBrightness: true, supportsColor: true, brightnessPct: 60,
                rgbColor: .warmWhite, colorTempKelvin: 2700, activePresetId: "warm_2700",
                activeEffect: "off", availableEffects: ["Scene", "Music", "off"],
                iconSystemName: "bed.double.fill", statusSubtitle: nil, powerWatts: nil
            )
        ]
    }
}

extension HASceneItem {
    public static var defaultMockupScenes: [HASceneItem] {
        [
            HASceneItem(id: "scene.cinema", name: "Cinema", iconSystemName: "film.stack.fill"),
            HASceneItem(id: "scene.jantar", name: L10n.t("Jantar", "Dinner"), iconSystemName: "fork.knife"),
            HASceneItem(id: "scene.boa_noite", name: L10n.t("Boa noite", "Good night"), iconSystemName: "moon.stars.fill"),
            HASceneItem(id: "scene.sair_de_casa", name: L10n.t("Sair de casa", "Leaving home"), iconSystemName: "lock.fill")
        ]
    }
}
