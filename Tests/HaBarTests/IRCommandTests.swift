import XCTest
@testable import HaBar

final class IRCommandTests: XCTestCase {
    override func setUp() { KeychainHelper.isIsolatedForTesting = true; L10n.forcedLanguage = "pt" }
    override func tearDown() { KeychainHelper.isIsolatedForTesting = false; L10n.forcedLanguage = nil }

    func testScriptsRemainUnassignedWithoutKnownRooms() {
        let states: [[String: Any]] = [
            ["entity_id": "script.jarvis_ar_escritorio_ligar_24", "state": "off"],
            ["entity_id": "script.jarvis_ar_escritorio_desligar", "state": "off"],
            ["entity_id": "script.jarvis_comando", "state": "off"]
        ]
        let result = HAEntityMapper.mapStates(states, entityToRoom: [:])
        XCTAssertEqual(result.devices.count, 3)
        XCTAssertTrue(result.devices.allSatisfy { $0.domain == .script && $0.room == .unassigned })
        XCTAssertTrue(result.devices.allSatisfy { $0.formattedStatusLine == "Toque para enviar" })
    }

    func testVirtualOfficeClimateAndIRScriptsJoinTheKnownOffice() throws {
        let office = HARoom(id: "escritorio", name: "Escritório")
        let states: [[String: Any]] = [
            ["entity_id":"climate.ar_do_escritorio", "state":"off", "attributes":["friendly_name":"Ar do escritório"]],
            ["entity_id":"script.jarvis_ar_escritorio_ligar_24", "state":"off"],
            ["entity_id":"script.jarvis_ar_escritorio_desligar", "state":"off"],
            ["entity_id":"light.escritorio", "state":"on"],
            ["entity_id":"media_player.fire_tv", "state":"unavailable"]
        ]
        let result = HAEntityMapper.mapStates(states, entityToRoom: ["light.escritorio":office, "media_player.fire_tv":office])
        XCTAssertEqual(result.devices.filter { $0.room.id == office.id }.count, 5)
        XCTAssertEqual(result.devices.first { $0.domain == .climate }?.room, office)
        XCTAssertEqual(result.devices.first { $0.domain == .mediaPlayer }?.availability, .unavailable)
    }
    func testRegisteredAreaWinsAndAmbiguousRoomNamesAreNotGuessed() {
        let office = HARoom(id: "escritorio", name: "Escritório")
        let bedroom = HARoom(id: "quarto", name: "Quarto")
        let states: [[String: Any]] = [
            ["entity_id":"climate.ar_escritorio", "state":"off"],
            ["entity_id":"script.quarto_e_escritorio", "state":"off"],
            ["entity_id":"script.escritorios", "state":"off"]
        ]
        let result = HAEntityMapper.mapStates(states, entityToRoom: ["climate.ar_escritorio":bedroom], rooms:[office,bedroom])
        XCTAssertEqual(result.devices.first { $0.domain == .climate }?.room, bedroom)
        XCTAssertTrue(result.devices.filter { $0.domain == .script }.allSatisfy { $0.room == .unassigned })
    }
    func testFriendlyNameCanAssignClimateToAnOtherwiseEmptyArea() {
        let office = HARoom(id: "area_uuid", name: "Escritório")
        let result = HAEntityMapper.mapStates([["entity_id":"climate.daikin", "state":"off", "attributes":["friendly_name":"Ar do ESCRITÓRIO"]]], entityToRoom: [:], rooms:[office])
        XCTAssertEqual(result.devices.first?.room, office)
    }

    func testScriptStateIsExecutionAndNotACPower() throws {
        let states: [[String: Any]] = [["entity_id": "script.jarvis_ar_escritorio_desligar", "state": "on"]]
        var command = try XCTUnwrap(HAEntityMapper.mapStates(states, entityToRoom: [:]).devices.first)
        XCTAssertEqual(command.formattedStatusLine, "Enviando comando…")
        HAEntityMapper.applyStateUpdate(["state": "off"], to: &command)
        XCTAssertEqual(command.formattedStatusLine, "Toque para enviar")
    }

    func testUnavailableCommandIsVisibleButDisabled() {
        let states: [[String: Any]] = [["entity_id": "script.jarvis_ar_escritorio_ligar_24", "state": "unavailable"]]
        XCTAssertEqual(HAEntityMapper.mapStates(states, entityToRoom: [:]).devices.first?.canControl, false)
    }
    func testClimateDoesNotHideUnrelatedScripts() throws {
        let states: [[String: Any]] = [
            ["entity_id":"climate.ar_do_escritorio", "state":"cool", "attributes":["friendly_name":"Ar do escritório", "temperature":25.0, "hvac_modes":["off","cool","heat"], "fan_modes":["auto","low","high"], "fan_mode":"auto", "assumed_state":true]],
            ["entity_id":"script.jarvis_ar_escritorio_ligar_24", "state":"off"]
        ]
        let result = HAEntityMapper.mapStates(states, entityToRoom: [:])
        XCTAssertEqual(result.devices.count, 2)
        var ac = try XCTUnwrap(result.devices.first { $0.domain == .climate })
        XCTAssertEqual(ac.domain, .climate)
        XCTAssertEqual(ac.room, .unassigned)
        XCTAssertEqual(ac.targetTemperature, 25)
        XCTAssertEqual(ac.fanMode, "auto")
        XCTAssertTrue(ac.formattedStatusLine.contains("estimado"))
        HAEntityMapper.applyStateUpdate(["state":"unknown", "attributes":["assumed_state":true, "hvac_modes":["off","cool"]]], to:&ac)
        XCTAssertFalse(ac.isOn)
        XCTAssertTrue(ac.canControl, "IR climate with no feedback must stay controllable after an HA restart")
        XCTAssertTrue(ac.canToggle)
        XCTAssertNil(ac.hvacMode)
        HAEntityMapper.applyStateUpdate(["state":"unknown", "attributes":[:]], to:&ac)
        XCTAssertFalse(ac.canControl, "Unknown climate with real feedback stays blocked")
    }

}
