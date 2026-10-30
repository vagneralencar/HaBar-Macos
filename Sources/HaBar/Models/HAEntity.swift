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
    case sensor
    case other
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
        return name
    }

    public var iconSystemName: String {
        let lower = (id + " " + name).lowercased()
        if id == "__favorites__" { return "star.fill" }
        if lower.contains("jantar") { return "fork.knife" }
        if lower.contains("tv") || lower.contains("estar") { return "tv.fill" }
        if lower.contains("escritorio") || lower.contains("escritório") || lower.contains("office") { return "desktopcomputer" }
        if lower.contains("quarto") || lower.contains("bedroom") { return "bed.double.fill" }
        if lower.contains("cozinha") || lower.contains("kitchen") { return "flame.fill" }
        if lower.contains("serviço") || lower.contains("servico") || lower.contains("laundry") { return "washer.fill" }
        return "house.fill"
    }

    public static let favorites = HARoom(id: "__favorites__", name: "Favoritos")
    public static let salaJantar = HARoom(id: "sala_de_estar", name: "Sala de jantar")
    public static let salaTV = HARoom(id: "sala_de_tv", name: "Sala de TV")
    public static let escritorio = HARoom(id: "escritorio", name: "Escritório")
    public static let quarto = HARoom(id: "quarto", name: "Quarto")
    public static let cozinha = HARoom(id: "cozinha", name: "Cozinha")
    public static let areaServico = HARoom(id: "area_de_servico", name: "Área de serviço")

    public static let defaultRooms: [HARoom] = [
        .favorites,
        .salaJantar,
        .salaTV,
        .escritorio,
        .quarto,
        .cozinha,
        .areaServico
    ]
}

public struct HAColorPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let rgb: RGBColor
    public let kelvin: Int?

    public var swiftUIColor: Color { rgb.swiftUIColor }

    public static let defaultPresets: [HAColorPreset] = [
        HAColorPreset(id: "warm_2700", name: "Branco\nQuente", subtitle: "2700K", rgb: .warmWhite, kelvin: 2700),
        HAColorPreset(id: "daylight_5000", name: "Luz do Dia", subtitle: "5000K", rgb: .daylight, kelvin: 5000),
        HAColorPreset(id: "sunset", name: "Pôr do Sol", subtitle: nil, rgb: .sunset, kelvin: nil),
        HAColorPreset(id: "cyberpunk", name: "Cyberpunk", subtitle: nil, rgb: .cyberpunk, kelvin: nil),
        HAColorPreset(id: "ocean", name: "Oceano", subtitle: nil, rgb: .ocean, kelvin: nil)
    ]
}

public struct HASceneItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var iconSystemName: String
    public var isActive: Bool

    public init(id: String, name: String, iconSystemName: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.isActive = isActive
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

    public static func modeTitle(_ mode: String) -> String {
        ["off":"Desligado", "cool":"Ar frio", "heat":"Ar quente", "auto":"Auto", "fan_only":"Ventilar", "dry":"Desumidificar"][mode] ?? mode
    }
    public static func fanTitle(_ mode: String) -> String {
        ["auto":"Auto", "low":"Fraco", "medium":"Médio", "high":"Forte"][mode] ?? mode
    }

    public var accentColor: Color {
        guard isOn else { return Color.white.opacity(0.35) }
        switch domain {
        case .light:
            return rgbColor.swiftUIColor
        case .climate:
            return AppTheme.cyanClimate
        case .switch:
            return AppTheme.amberAccent
        default:
            return AppTheme.greenOnline
        }
    }

    public var formattedStatusLine: String {
        if domain == .climate {
            let label = Self.modeTitle(hvacMode ?? "Sem estado")
            return label + (isAssumedState ? " · estimado" : "")
        }
        if domain == .script { return isOn ? "Enviando comando…" : "Toque para enviar" }
        if let custom = statusSubtitle, domain != .light {
            return isOn ? custom : "Desligado"
        }
        if domain == .light && supportsBrightness {
            return isOn ? "Ligado • \(Int(brightnessPct.rounded()))%" : "Desligado"
        }
        return isOn ? "Ligado" : "Desligado"
    }
}

// MARK: - Pure Mapper for Home Assistant JSON States & Areas

public enum HAEntityMapper {
    // Only expose the two public AC actions, not internal household helper scripts.
    private static let airConditionerCommands: [String: (name: String, icon: String)] = [
        "script.jarvis_ar_escritorio_ligar_24": ("Ar · ligar a 24 °C", "snowflake"),
        "script.jarvis_ar_escritorio_desligar": ("Ar · desligar", "power")
    ]
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
        entityToRoom: [String: HARoom]
    ) -> (devices: [HADeviceItem], scenes: [HASceneItem]) {
        var parsedDevices: [HADeviceItem] = []
        var parsedScenes: [HASceneItem] = []

        let ignoredSuffixes = KeychainHelper.ignoredEntitySuffixes
        let stripPrefixes = KeychainHelper.stripScenePrefixes

        for stateObj in states {
            guard let entityId = stateObj["entity_id"] as? String,
                  let stateStr = stateObj["state"] as? String else { continue }

            // Skip unavailable entities and configured auxiliary suffixes
            if stateStr == "unavailable" ||
               ignoredSuffixes.contains(where: { entityId.hasSuffix($0) }) {
                continue
            }

            let attrs = stateObj["attributes"] as? [String: Any] ?? [:]
            let friendlyName = ((attrs["friendly_name"] as? String) ?? entityId)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if entityId.hasPrefix("scene.") {
                let displayName = cleanSceneName(friendlyName, stripPrefixes: stripPrefixes)
                parsedScenes.append(
                    HASceneItem(
                        id: entityId,
                        name: displayName,
                        iconSystemName: iconForScene(id: entityId, name: friendlyName),
                        isActive: false
                    )
                )
            } else if entityId.hasPrefix("climate.") {
                var climate = HADeviceItem(
                    id: entityId, name: friendlyName, domain: .climate,
                    room: entityToRoom[entityId] ?? inferRoom(from: "\(entityId) \(friendlyName)"),
                    isFavorite: true, isOn: !["off", "unknown", "unavailable"].contains(stateStr),
                    supportsBrightness: false, supportsColor: false,
                    brightnessPct: 0, rgbColor: .climateCyan, colorTempKelvin: nil,
                    activePresetId: nil, activeEffect: "", availableEffects: [],
                    iconSystemName: "air.conditioner.horizontal.fill", statusSubtitle: nil, powerWatts: nil
                )
                climate.targetTemperature = attrs["temperature"] as? Double
                climate.minTemperature = attrs["min_temp"] as? Double ?? 16
                climate.maxTemperature = attrs["max_temp"] as? Double ?? 30
                climate.hvacMode = stateStr
                climate.hvacModes = attrs["hvac_modes"] as? [String] ?? []
                climate.fanMode = attrs["fan_mode"] as? String
                climate.fanModes = attrs["fan_modes"] as? [String] ?? []
                climate.isAssumedState = attrs["assumed_state"] as? Bool ?? false
                parsedDevices.append(climate)
            } else if entityId.hasPrefix("light.") {
                let isOn = (stateStr == "on")
                let colorModes = (attrs["supported_color_modes"] as? [String]) ?? []
                let supportsColor = colorModes.contains("hs") || colorModes.contains("rgb") || colorModes.contains("color_temp") || colorModes.contains("xy")
                let supportsBrightness = supportsColor || colorModes.contains("brightness")

                let rawBrightness = (attrs["brightness"] as? Double) ?? (isOn ? 255.0 : 0.0)
                let pct = min(100, max(0, (rawBrightness / 255.0) * 100.0))
                let rgb = extractRGB(from: attrs) ?? .warmWhite
                let effects = (attrs["effect_list"] as? [String]) ?? (supportsColor ? ["Scene", "Music", "off"] : [])
                let currentEffect = (attrs["effect"] as? String) ?? (effects.first ?? "off")
                let room = entityToRoom[entityId] ?? inferRoom(from: "\(entityId) \(friendlyName)")
                let isBacklight = entityId.contains("luz_de_fundo")
                let isGroupOrPrimary = (attrs["entity_id"] as? [String]) != nil || supportsColor

                parsedDevices.append(
                    HADeviceItem(
                        id: entityId,
                        name: friendlyName,
                        domain: .light,
                        room: room,
                        isFavorite: !isBacklight && isGroupOrPrimary,
                        isOn: isOn,
                        supportsBrightness: supportsBrightness,
                        supportsColor: supportsColor,
                        brightnessPct: isOn ? max(pct, 5) : 0,
                        rgbColor: rgb,
                        colorTempKelvin: (attrs["color_temp_kelvin"] as? Double).map { Int($0) } ?? (attrs["color_temp_kelvin"] as? Int),
                        activePresetId: nil,
                        activeEffect: currentEffect,
                        availableEffects: effects,
                        iconSystemName: iconForLight(id: entityId, name: friendlyName),
                        statusSubtitle: nil,
                        powerWatts: nil
                    )
                )
            } else if let command = airConditionerCommands[entityId] {
                parsedDevices.append(HADeviceItem(
                    id: entityId, name: command.name, domain: .script,
                    room: entityToRoom[entityId] ?? .escritorio,
                    isFavorite: true, isOn: stateStr == "on",
                    supportsBrightness: false, supportsColor: false,
                    brightnessPct: 0, rgbColor: .climateCyan, colorTempKelvin: nil,
                    activePresetId: nil, activeEffect: "", availableEffects: [],
                    iconSystemName: command.icon, statusSubtitle: nil, powerWatts: nil
                ))
            } else if entityId.hasPrefix("switch.") {
                let isOn = (stateStr == "on")
                let room = entityToRoom[entityId] ?? inferRoom(from: "\(entityId) \(friendlyName)")

                parsedDevices.append(
                    HADeviceItem(
                        id: entityId,
                        name: friendlyName,
                        domain: .switch,
                        room: room,
                        isFavorite: true,
                        isOn: isOn,
                        supportsBrightness: false,
                        supportsColor: false,
                        brightnessPct: 100,
                        rgbColor: .warmWhite,
                        colorTempKelvin: nil,
                        activePresetId: nil,
                        activeEffect: "",
                        availableEffects: [],
                        iconSystemName: iconForSwitch(name: friendlyName),
                        statusSubtitle: isOn ? "Ligado" : "Desligado",
                        powerWatts: nil
                    )
                )
            }
        }

        if parsedDevices.contains(where: { $0.id == "climate.ar_do_escritorio" }) {
            parsedDevices.removeAll { airConditionerCommands[$0.id] != nil }
        }
        parsedScenes.sort { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        parsedDevices.sort { a, b in
            let aBacklight = a.id.contains("luz_de_fundo")
            let bBacklight = b.id.contains("luz_de_fundo")
            if aBacklight != bBacklight { return !aBacklight }
            if a.supportsBrightness != b.supportsBrightness { return a.supportsBrightness }
            return a.name < b.name
        }

        return (parsedDevices, parsedScenes)
    }

    public static func applyStateUpdate(_ stateObj: [String: Any], to item: inout HADeviceItem) {
        guard let stateStr = stateObj["state"] as? String else { return }
        let attrs = stateObj["attributes"] as? [String: Any] ?? [:]
        item.isOn = (stateStr == "on" || (item.domain == .climate && !["off", "unknown", "unavailable"].contains(stateStr)))
        if item.domain == .climate {
            item.hvacMode = stateStr
            item.targetTemperature = attrs["temperature"] as? Double
            item.fanMode = attrs["fan_mode"] as? String
            item.isAssumedState = attrs["assumed_state"] as? Bool ?? false
        }
        if let rawBrightness = attrs["brightness"] as? Double {
            item.brightnessPct = min(100, max(0, (rawBrightness / 255.0) * 100.0))
        }
        if let rgb = extractRGB(from: attrs) {
            item.rgbColor = rgb
        }
        if item.domain == .switch {
            item.statusSubtitle = item.isOn ? "Ligado" : "Desligado"
        }
    }

    private static func cleanSceneName(_ raw: String, stripPrefixes: [String]) -> String {
        for prefix in stripPrefixes {
            if raw.lowercased().hasPrefix(prefix.lowercased()) {
                return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return raw
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

    private static func inferRoom(from text: String) -> HARoom {
        let lower = text.lowercased()
        if lower.contains("escritorio") || lower.contains("escritório") {
            return .escritorio
        }
        if lower.contains("quarto") || lower.contains("abajur") {
            return .quarto
        }
        if lower.contains("cozinha") {
            return .cozinha
        }
        if lower.contains("serviço") || lower.contains("servico") {
            return .areaServico
        }
        if lower.contains("tv") {
            return .salaTV
        }
        return .salaJantar
    }

    private static func iconForLight(id: String, name: String) -> String {
        let lower = (id + " " + name).lowercased()
        if lower.contains("abajur") { return "lamp.table.fill" }
        if lower.contains("spot") { return "light.recessed.fill" }
        if lower.contains("escritorio") || lower.contains("escritório") { return "lamp.desk.fill" }
        if lower.contains("quarto") { return "bed.double.fill" }
        if lower.contains("luz_de_fundo") { return "switch.2" }
        return "lightbulb.fill"
    }

    private static func iconForSwitch(name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("tv") { return "tv.fill" }
        if lower.contains("cozinha") || lower.contains("luz") || lower.contains("spot") { return "lightbulb.2.fill" }
        return "poweroutlet.type.b.fill"
    }

    private static func iconForScene(id: String, name: String) -> String {
        let lower = (id + " " + name).lowercased()
        if lower.contains("cinema") { return "film.stack.fill" }
        if lower.contains("jantar") { return "fork.knife" }
        if lower.contains("trabalho") { return "desktopcomputer" }
        if lower.contains("relaxar") { return "sofa.fill" }
        if lower.contains("boa_noite") || lower.contains("boa noite") { return "moon.stars.fill" }
        if lower.contains("cheguei") { return "house.fill" }
        if lower.contains("sair") { return "lock.fill" }
        if lower.contains("desligar") { return "lightbulb.slash.fill" }
        return "sparkles"
    }
}

// MARK: - Generic Open Source Demo Entities (Fallback when not connected)
extension HADeviceItem {
    public static let defaultMockupDevices: [HADeviceItem] = [
        HADeviceItem(
            id: "light.spots_sala_jantar",
            name: "Spots — Sala de Jantar",
            domain: .light,
            room: .salaJantar,
            isFavorite: true,
            isOn: true,
            supportsBrightness: true,
            supportsColor: true,
            brightnessPct: 80,
            rgbColor: .warmWhite,
            colorTempKelvin: 2700,
            activePresetId: "warm_2700",
            activeEffect: "off",
            availableEffects: ["Scene", "Music", "off"],
            iconSystemName: "light.recessed.fill",
            statusSubtitle: nil,
            powerWatts: nil
        ),
        HADeviceItem(
            id: "light.escritorio",
            name: "Luz Escritório",
            domain: .light,
            room: .escritorio,
            isFavorite: true,
            isOn: true,
            supportsBrightness: true,
            supportsColor: true,
            brightnessPct: 100,
            rgbColor: .daylight,
            colorTempKelvin: 5000,
            activePresetId: "daylight_5000",
            activeEffect: "off",
            availableEffects: ["Scene", "Music", "off"],
            iconSystemName: "lamp.desk.fill",
            statusSubtitle: nil,
            powerWatts: nil
        ),
        HADeviceItem(
            id: "switch.sala_tv",
            name: "Luz da Sala de TV",
            domain: .switch,
            room: .salaTV,
            isFavorite: true,
            isOn: false,
            supportsBrightness: false,
            supportsColor: false,
            brightnessPct: 100,
            rgbColor: .warmWhite,
            colorTempKelvin: nil,
            activePresetId: nil,
            activeEffect: "",
            availableEffects: [],
            iconSystemName: "tv.fill",
            statusSubtitle: "Desligado",
            powerWatts: nil
        ),
        HADeviceItem(
            id: "light.luz_quarto",
            name: "Luz do Quarto",
            domain: .light,
            room: .quarto,
            isFavorite: true,
            isOn: false,
            supportsBrightness: true,
            supportsColor: true,
            brightnessPct: 60,
            rgbColor: .warmWhite,
            colorTempKelvin: 2700,
            activePresetId: "warm_2700",
            activeEffect: "off",
            availableEffects: ["Scene", "Music", "off"],
            iconSystemName: "bed.double.fill",
            statusSubtitle: nil,
            powerWatts: nil
        )
    ]
}

extension HASceneItem {
    public static let defaultMockupScenes: [HASceneItem] = [
        HASceneItem(id: "scene.cinema", name: "Cinema", iconSystemName: "film.stack.fill", isActive: false),
        HASceneItem(id: "scene.jantar", name: "Jantar", iconSystemName: "fork.knife", isActive: false),
        HASceneItem(id: "scene.boa_noite", name: "Boa noite", iconSystemName: "moon.stars.fill", isActive: false),
        HASceneItem(id: "scene.sair_de_casa", name: "Sair de casa", iconSystemName: "lock.fill", isActive: false)
    ]
}
