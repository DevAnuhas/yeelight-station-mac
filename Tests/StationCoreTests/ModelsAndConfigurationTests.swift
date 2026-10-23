import Foundation
import XCTest
@testable import StationCore

final class ModelsAndConfigurationTests: XCTestCase {
    func testRecoveredPresetCountsAndValues() throws {
        let presets = try StationPresets.load()
        XCTAssertEqual(presets.scenes.count, 10)
        XCTAssertEqual(presets.palettes.count, 45)
        XCTAssertEqual(presets.layouts.count, 8)
        let relax = try XCTUnwrap(presets.scenes.first { $0.name == "Relax" })
        XCTAssertEqual(relax.temperature, 4000); XCTAssertEqual(relax.brightness, 60)
        let layout = try XCTUnwrap(presets.layouts.first { $0.id == "2" })
        XCTAssertEqual(layout.zones.count, 6)
        XCTAssertEqual(layout.zones[1], SampleRect(x: 0, y: 0, width: 0.5, height: 0.3))
        XCTAssertTrue(presets.palettes.allSatisfy { $0.colors.count == 5 })
        XCTAssertEqual(Set(presets.palettes.map(\.id)).count, presets.palettes.count)
        for layout in presets.layouts {
            for zone in layout.zones {
                XCTAssertGreaterThan(zone.width, 0); XCTAssertGreaterThan(zone.height, 0)
                XCTAssertLessThanOrEqual(zone.x + zone.width, 1); XCTAssertLessThanOrEqual(zone.y + zone.height, 1)
            }
        }
    }
    func testJSONRoundTripPreservesTokenAndNumericKeepalive() throws {
        let value = JSONValue.object(["id": .int(3), "token": .string("token"), "method": .string("udp_sess_keep_alive"), "params": .array([.string("keeplive_interval"), .int(10)])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
    func testRGBPackingAndScaling() {
        let color = StationCore.RGBColor(red: 0x12, green: 0x34, blue: 0x56)
        XCTAssertEqual(color.packed, 0x123456); XCTAssertEqual(color.hex, "#123456")
        XCTAssertEqual(StationCore.RGBColor(packed: 0x123456), color)
        XCTAssertEqual(color.scaled(0), .black); XCTAssertEqual(color.scaled(2), color)
    }
    func testAtomicConfigurationRoundTripAndUnknownVersionDoesNotOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        XCTAssertTrue(try store.load().devices.isEmpty)
        var config = StationConfiguration()
        config.devices = [LightDevice(id: "light-1", name: "Desk", model: "lamp15", host: "192.0.2.1")]
        config.assignments["light-1"] = DeviceAssignment(deviceID: "light-1", channel: .background, zone: 2)
        try store.save(config)
        XCTAssertEqual(try store.load().devices, config.devices)
        XCTAssertEqual(try store.load().assignments["light-1"]?.zone, 2)
        config.version = 999; try store.save(config)
        let before = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }
    func testInvalidSettingsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        var config = StationConfiguration(); config.frameInterval = -1
        try store.save(config); XCTAssertThrowsError(try store.load())
    }
    func testNonFinitePropertiesCannotReachUIConversions() {
        XCTAssertEqual(LightProperties.number("nan", fallback: 50, range: 1...100), 50)
        XCTAssertEqual(LightProperties.number("inf", fallback: 50, range: 1...100), 50)
        XCTAssertEqual(LightProperties.number("1e309", fallback: 50, range: 1...100), 50)
        XCTAssertEqual(LightProperties.number("999999999999999999999", fallback: 50, range: 1...100), 100)
        XCTAssertFalse(LightProperties.validate(["bg_bright": "nan"]))
        XCTAssertFalse(LightProperties.validate(["ct": "inf"]))
        XCTAssertTrue(LightProperties.validate(["ct": "4000", "bg_rgb": "16777215"]))
    }
    func testLampSceneChannelsAndWhiteFlowTranslation() throws {
        let presets = try StationPresets.load()
        let lamp = LightDevice(id: "lamp", name: "Desk", model: "lamp15", host: "192.0.2.1")
        let gaming = try XCTUnwrap(presets.scenes.first { $0.name == "Gaming" })
        let candle = try XCTUnwrap(presets.scenes.first { $0.name == "Candle light" })
        let fireworks = try XCTUnwrap(presets.scenes.first { $0.name == "Fireworks" })
        XCTAssertThrowsError(try SceneCompatibility.adapted(gaming, device: lamp, channel: .main))
        XCTAssertThrowsError(try SceneCompatibility.adapted(fireworks, device: lamp, channel: .main))
        XCTAssertEqual(try SceneCompatibility.adapted(candle, device: lamp, channel: .main).flow, candle.flow)
        let converted = try SceneCompatibility.adapted(candle, device: lamp, channel: .background)
        let parts = converted.flow.split(separator: ",")
        XCTAssertEqual(parts[3], "1")
        XCTAssertEqual(Int(parts[4]), SceneCompatibility.whiteRGB(2900).packed)
        XCTAssertEqual(parts[5], "75")
        XCTAssertEqual(parts.count, candle.flow.split(separator: ",").count)
    }

}
