import Foundation

public enum SceneCompatibility {
    /// Lamp task LEDs are white-only; their backlight uses RGB. Translate CT output only where necessary.
    public static func adapted(_ preset: ScenePreset, device: LightDevice, channel: LightChannel) throws -> ScenePreset {
        guard device.hasBackground else { return preset }
        var result = preset
        let fields = preset.flow.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let tuples = fields.count >= 2 ? Array(fields.dropFirst(2)) : []
        let modes = stride(from: 1, to: tuples.count, by: 4).compactMap { Int(tuples[$0]) }
        if channel == .main {
            guard preset.rgb == 0, !modes.contains(1) else {
                throw StationError.unavailable("\(preset.name) is an RGB scene. Select the RGB backlight for \(device.displayName).")
            }
            return result
        }
        if result.temperature > 0 {
            result.rgb = whiteRGB(result.temperature).packed; result.temperature = 0
        }
        if !tuples.isEmpty {
            guard tuples.count.isMultiple(of: 4) else { throw StationError.invalidResponse("The scene contains an invalid color flow.") }
            var converted = fields
            for i in stride(from: 0, to: tuples.count, by: 4) where Int(tuples[i + 1]) == 2 {
                guard let kelvin = Int(tuples[i + 2]) else { throw StationError.invalidResponse("The scene contains an invalid white temperature.") }
                converted[i + 3] = "1"
                converted[i + 4] = String(whiteRGB(kelvin).packed)
            }
            result.flow = converted.joined(separator: ",")
        }
        return result
    }

    /// Approximate sRGB representation of a white temperature, for a color-only channel.
    public static func whiteRGB(_ kelvin: Int) -> RGBColor {
        let t = Double(min(6500, max(1700, kelvin))) / 100
        let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        return RGBColor(red: UInt8(min(255, max(0, red))), green: UInt8(min(255, max(0, green))), blue: UInt8(min(255, max(0, blue))))
    }
}
