import XCTest
@testable import HaBar

final class EntityMapperTests: XCTestCase {
    func testMapCoversFansAndLocks() throws {
        let states: [[String: Any]] = [
            [
                "entity_id": "cover.persiana_sala",
                "state": "open",
                "attributes": ["friendly_name": "Persiana da Sala", "current_position": 85]
            ],
            [
                "entity_id": "fan.ventilador_quarto",
                "state": "on",
                "attributes": ["friendly_name": "Ventilador"]
            ],
            [
                "entity_id": "lock.porta_entrada",
                "state": "locked",
                "attributes": ["friendly_name": "Fechadura Entrada"]
            ]
        ]

        let result = HAEntityMapper.mapStates(states, entityToRoom: [:])
        XCTAssertEqual(result.devices.count, 3)

        let cover = try XCTUnwrap(result.devices.first { $0.domain == .cover })
        XCTAssertEqual(cover.name, "Persiana da Sala")
        XCTAssertEqual(cover.coverPosition, 85)
        XCTAssertTrue(cover.isOn)

        let fan = try XCTUnwrap(result.devices.first { $0.domain == .fan })
        XCTAssertEqual(fan.name, "Ventilador")
        XCTAssertTrue(fan.isOn)

        let lock = try XCTUnwrap(result.devices.first { $0.domain == .lock })
        XCTAssertEqual(lock.name, "Fechadura Entrada")
        XCTAssertFalse(lock.isOn) // locked = not on (closed)
    }

    func testSensorsOnlyIncludedWhenAssignedToRoom() throws {
        let office = HARoom(id: "escritorio", name: "Escritório")
        let states: [[String: Any]] = [
            [
                "entity_id": "sensor.temperatura_escritorio",
                "state": "23.5",
                "attributes": [
                    "friendly_name": "Temperatura Escritório",
                    "device_class": "temperature",
                    "unit_of_measurement": "°C"
                ]
            ],
            [
                "entity_id": "sensor.temperatura_externa_orfa",
                "state": "19.0",
                "attributes": [
                    "device_class": "temperature",
                    "unit_of_measurement": "°C"
                ]
            ]
        ]

        // When not mapped to room, orphan read-only sensors are filtered out to avoid clutter
        let filtered = HAEntityMapper.mapStates(states, entityToRoom: [:])
        XCTAssertEqual(filtered.devices.count, 0)

        // When placed in room, sensor is mapped with units
        let mapped = HAEntityMapper.mapStates(states, entityToRoom: ["sensor.temperatura_escritorio": office])
        XCTAssertEqual(mapped.devices.count, 1)
        let tempSensor = try XCTUnwrap(mapped.devices.first)
        XCTAssertEqual(tempSensor.domain, .sensor)
        XCTAssertTrue(tempSensor.isReadOnly)
        XCTAssertEqual(tempSensor.statusSubtitle, "23.5 °C")
    }

    func testSceneActiveDetectionFromTimestamp() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recentTimestamp = formatter.string(from: now.addingTimeInterval(-30)) // 30s ago
        let oldTimestamp = formatter.string(from: now.addingTimeInterval(-3600)) // 1h ago

        let states: [[String: Any]] = [
            [
                "entity_id": "scene.cinema",
                "state": recentTimestamp,
                "attributes": ["friendly_name": "Cinema", "entity_id": ["light.spot_1"]]
            ],
            [
                "entity_id": "scene.boa_noite",
                "state": oldTimestamp,
                "attributes": ["friendly_name": "Boa Noite"]
            ]
        ]

        let result = HAEntityMapper.mapStates(states, entityToRoom: [:], now: now)
        XCTAssertEqual(result.scenes.count, 2)

        let cinema = try XCTUnwrap(result.scenes.first { $0.id == "scene.cinema" })
        let boaNoite = try XCTUnwrap(result.scenes.first { $0.id == "scene.boa_noite" })

        XCTAssertTrue(cinema.isActive)
        XCTAssertEqual(cinema.memberEntityIds, ["light.spot_1"])
        XCTAssertFalse(boaNoite.isActive)
    }

    func testLightColorModesAndBrightness() throws {
        let states: [[String: Any]] = [
            [
                "entity_id": "light.luz_teto",
                "state": "on",
                "attributes": [
                    "friendly_name": "Luz do Teto",
                    "brightness": 128,
                    "supported_color_modes": ["hs", "rgb"],
                    "rgb_color": [255, 120, 50],
                    "effect_list": ["Rainbow", "Strobe", "off"],
                    "effect": "Rainbow"
                ]
            ]
        ]

        let result = HAEntityMapper.mapStates(states, entityToRoom: [:])
        let light = try XCTUnwrap(result.devices.first)
        XCTAssertEqual(light.domain, .light)
        XCTAssertTrue(light.supportsBrightness)
        XCTAssertTrue(light.supportsColor)
        XCTAssertEqual(Int(light.brightnessPct.rounded()), 50)
        XCTAssertEqual(light.rgbColor.red, 255)
        XCTAssertEqual(light.rgbColor.green, 120)
        XCTAssertEqual(light.rgbColor.blue, 50)
        XCTAssertEqual(light.activeEffect, "Rainbow")
    }
}
