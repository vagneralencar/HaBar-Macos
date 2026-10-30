import XCTest
@testable import HaBar

final class IRCommandTests: XCTestCase {
    func testPublicAirCommandsAppearInOfficeButHelpersDoNot() {
        let states: [[String: Any]] = [
            ["entity_id": "script.jarvis_ar_escritorio_ligar_24", "state": "off"],
            ["entity_id": "script.jarvis_ar_escritorio_desligar", "state": "off"],
            ["entity_id": "script.jarvis_comando", "state": "off"]
        ]
        let result = HAEntityMapper.mapStates(states, entityToRoom: [:])
        XCTAssertEqual(result.devices.count, 2)
        XCTAssertTrue(result.devices.allSatisfy { $0.domain == .script && $0.room == .escritorio })
        XCTAssertTrue(result.devices.allSatisfy { $0.formattedStatusLine == "Toque para enviar" })
    }

    func testScriptStateIsExecutionAndNotACPower() throws {
        let states: [[String: Any]] = [["entity_id": "script.jarvis_ar_escritorio_desligar", "state": "on"]]
        var command = try XCTUnwrap(HAEntityMapper.mapStates(states, entityToRoom: [:]).devices.first)
        XCTAssertEqual(command.formattedStatusLine, "Enviando comando…")
        HAEntityMapper.applyStateUpdate(["state": "off"], to: &command)
        XCTAssertEqual(command.formattedStatusLine, "Toque para enviar")
    }

    func testUnavailableCommandIsNotOffered() {
        let states: [[String: Any]] = [["entity_id": "script.jarvis_ar_escritorio_ligar_24", "state": "unavailable"]]
        XCTAssertTrue(HAEntityMapper.mapStates(states, entityToRoom: [:]).devices.isEmpty)
    }
    func testClimateCarriesControlsAndHidesDuplicateACScripts() throws {
        let states: [[String: Any]] = [
            ["entity_id":"climate.ar_do_escritorio", "state":"cool", "attributes":["friendly_name":"Ar do escritório", "temperature":25.0, "hvac_modes":["off","cool","heat"], "fan_modes":["auto","low","high"], "fan_mode":"auto", "assumed_state":true]],
            ["entity_id":"script.jarvis_ar_escritorio_ligar_24", "state":"off"]
        ]
        let result = HAEntityMapper.mapStates(states, entityToRoom: [:])
        XCTAssertEqual(result.devices.count, 1)
        var ac = try XCTUnwrap(result.devices.first)
        XCTAssertEqual(ac.domain, .climate)
        XCTAssertEqual(ac.room, .escritorio)
        XCTAssertEqual(ac.targetTemperature, 25)
        XCTAssertEqual(ac.fanMode, "auto")
        XCTAssertTrue(ac.formattedStatusLine.contains("estimado"))
        HAEntityMapper.applyStateUpdate(["state":"unknown", "attributes":["assumed_state":true]], to:&ac)
        XCTAssertFalse(ac.isOn)
    }

}
