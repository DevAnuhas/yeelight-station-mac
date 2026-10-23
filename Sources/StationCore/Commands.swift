import Foundation

/// Commands for ordinary, acknowledged LAN controls. Realtime frames use the UDP session instead.
public enum LightCommands {
    public static func power(_ on: Bool, channel: LightChannel) -> (String, [JSONValue]) {
        (channel.method("set_power"), [.string(on ? "on" : "off"), .string("smooth"), .int(300)])
    }

    public static func brightness(_ value: Int, channel: LightChannel) -> (String, [JSONValue]) {
        (channel.method("set_bright"), [.int(min(100, max(1, value))), .string("smooth"), .int(300)])
    }

    public static func temperature(_ value: Int, channel: LightChannel) -> (String, [JSONValue]) {
        (channel.method("set_ct_abx"), [.int(min(6500, max(1700, value))), .string("smooth"), .int(300)])
    }

    public static func color(_ rgb: RGBColor, channel: LightChannel) -> (String, [JSONValue]) {
        (channel.method("set_rgb"), [.int(rgb.packed), .string("smooth"), .int(300)])
    }

    public static func scene(_ preset: ScenePreset, channel: LightChannel) -> [(String, [JSONValue])] {
        if preset.powerMode == 1 { return [power(false, channel: channel)] }
        if preset.powerMode == 2 { return [power(true, channel: channel)] }
        if !preset.flow.isEmpty {
            // Station stores count, stop action, and the flow tuples in one comma-separated string.
            let parts = preset.flow.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let count = Int(parts[0]), let action = Int(parts[1]),
                  count >= 0, (0...2).contains(action) else { return [] }
            return [(channel.method("set_scene"), [.string("cf"), .int(count), .int(action), .string(String(parts[2]))])]
        }
        let bright = JSONValue.int(min(100, max(1, preset.brightness)))
        if preset.temperature > 0 {
            return [(channel.method("set_scene"), [.string("ct"), .int(min(6500, max(1700, preset.temperature))), bright])]
        }
        return [(channel.method("set_scene"), [.string("color"), .int(min(0xFFFFFF, max(0, preset.rgb))), bright])]
    }
}
