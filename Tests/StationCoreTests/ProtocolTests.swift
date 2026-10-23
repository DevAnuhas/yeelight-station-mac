import XCTest
@testable import StationCore

final class ProtocolTests: XCTestCase {
    func testChannelCommandsAndBounds() {
        let power = LightCommands.power(true, channel: .background)
        XCTAssertEqual(power.0, "bg_set_power")
        XCTAssertEqual(power.1, [.string("on"), .string("smooth"), .int(300)])
        XCTAssertEqual(LightCommands.brightness(-9, channel: .main).1.first, .int(1))
        XCTAssertEqual(LightCommands.brightness(999, channel: .background).1.first, .int(100))
        XCTAssertEqual(LightCommands.temperature(9999, channel: .main).1.first, .int(6500))
        XCTAssertEqual(LightCommands.temperature(0, channel: .main).1.first, .int(1700))
        let color = LightCommands.color(RGBColor(red: 255, green: 1, blue: 2), channel: .main)
        XCTAssertEqual(color.0, "set_rgb")
        XCTAssertEqual(color.1.first, .int(0xFF0102))
    }

    func testRecoveredSceneIncludesCountAndStopAction() throws {
        let presets = try StationPresets.load()
        let candle = try XCTUnwrap(presets.scenes.first { $0.name == "Candle light" })
        let commands = LightCommands.scene(candle, channel: .background)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.0, "bg_set_scene")
        XCTAssertEqual(commands.first?.1.prefix(3), [.string("cf"), .int(0), .int(0)])
        XCTAssertEqual(commands.first?.1.last?.text?.split(separator: ",").count, 32)
        let working = try XCTUnwrap(presets.scenes.first { $0.name == "Working" })
        XCTAssertEqual(LightCommands.scene(working, channel: .main).first?.1, [.string("ct"), .int(5000), .int(100)])
        let off = try XCTUnwrap(presets.scenes.first { $0.name == "Light off" })
        XCTAssertEqual(LightCommands.scene(off, channel: .main).first?.0, "set_power")
        XCTAssertEqual(LightCommands.scene(off, channel: .main).first?.1.first, .string("off"))
    }

    func testRecoveredSegmentedEncodings() throws {
        let colors = [RGBColor(packed: 0xFF0000), RGBColor(packed: 0x00FF00), RGBColor(packed: 0x0000FF)]
        var device = LightDevice(id: "strip", name: "", model: "strip", host: "127.0.0.1", support: ["update_leds"])
        let extended = try RealtimeCommands.frame(device: device, colors: colors, channel: .main, brightness: 100)
        XCTAssertEqual(extended.0, "update_leds")
        XCTAssertEqual(extended.1, [.string("/wAAAP8AAAD/")])
        device.support = ["set_segment_rgb"]
        let legacy = try RealtimeCommands.frame(device: device, colors: colors, channel: .main, brightness: 100)
        XCTAssertEqual(legacy.0, "set_segment_rgb")
        XCTAssertEqual(legacy.1, [.int(0xFF0000), .int(0x00FF00), .int(0x0000FF)])
    }

    func testLampRealtimeOnlyUsesBacklight() throws {
        let device = LightDevice(id: "lamp", name: "", model: "lamp15", host: "127.0.0.1", support: ["udp_sess_new", "set_scene", "bg_set_rgb"])
        XCTAssertThrowsError(try RealtimeCommands.frame(device: device, colors: [.black], channel: .main, brightness: 100))
        let command = try RealtimeCommands.frame(device: device, colors: [RGBColor(packed: 0xFF0000)], channel: .background, brightness: 50)
        XCTAssertEqual(command.0, "bg_set_rgb")
        XCTAssertEqual(command.1, [.int(0x7F0000), .string("sudden"), .int(0)])
        XCTAssertThrowsError(try RealtimeCommands.frame(device: device, colors: [], channel: .background, brightness: 100))
    }

    func testUDPSceneExtensionUsesUnprefixedMainMethod() throws {
        let device = LightDevice(id: "bulb", name: "", model: "color4", host: "127.0.0.1", support: ["set_scene"])
        let command = try RealtimeCommands.frame(device: device, colors: [RGBColor(packed: 0x112233)], channel: .main, brightness: 25)
        XCTAssertEqual(command.0, "set_scene")
        XCTAssertEqual(command.1, [.string("color"), .int(0x112233), .int(25), .int(0), .string("sudden")])
        let dark = try RealtimeCommands.frame(device: device, colors: [RGBColor(packed: 0xFFFFFF)], channel: .main, brightness: 0)
        XCTAssertEqual(dark.1, [.string("color"), .int(0), .int(1), .int(0), .string("sudden")])
    }
    func testLampWholeBacklightColorDoesNotBecomeOneSegment() throws {
        let device = LightDevice(id: "lamp", name: "", model: "lamp15", host: "127.0.0.1", support: ["udp_sess_new", "set_segment_rgb", "bg_set_scene", "bg_set_rgb"])
        let frame = try RealtimeCommands.frame(device: device, colors: [RGBColor(packed: 0x123456)], channel: .background, brightness: 30)
        XCTAssertEqual(frame.0, "bg_set_scene")
        XCTAssertEqual(frame.1, [.string("color"), .int(0x123456), .int(30), .int(0), .string("sudden")])
    }

}
