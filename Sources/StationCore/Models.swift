import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var text: String? {
        switch self { case .string(let v): return v; case .int(let v): return String(v); default: return nil }
    }
    public var integer: Int? { if case .int(let v) = self { return v }; return text.flatMap(Int.init) }
    public var dictionary: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var values: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
}

public struct RGBColor: Codable, Sendable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
    public init(packed: Int) { red = UInt8((packed >> 16) & 255); green = UInt8((packed >> 8) & 255); blue = UInt8(packed & 255) }
    public var packed: Int { (Int(red) << 16) | (Int(green) << 8) | Int(blue) }
    public var hex: String { String(format: "#%06X", packed) }
    public static let black = RGBColor(packed: 0)
    public func scaled(_ factor: Double) -> RGBColor {
        guard factor.isFinite else { return .black }
        let f = min(1, max(0, factor))
        return RGBColor(red: UInt8(Double(red) * f), green: UInt8(Double(green) * f), blue: UInt8(Double(blue) * f))
    }
}

public struct SampleRect: Codable, Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct ScreenLayout: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var zones: [SampleRect]
}

public enum LightChannel: String, Codable, Sendable, CaseIterable, Identifiable {
    case main, background
    public var id: String { rawValue }
    public var title: String { self == .main ? "Task light" : "RGB backlight" }
    public func method(_ method: String) -> String { self == .background ? "bg_" + method : method }
}

public struct LightDevice: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var model: String
    public var host: String
    public var port: UInt16
    public var support: Set<String>
    public var properties: [String: String]
    public init(id: String, name: String, model: String, host: String, port: UInt16 = 55443, support: Set<String> = [], properties: [String: String] = [:]) {
        self.id = id; self.name = name; self.model = model; self.host = host; self.port = port; self.support = support; self.properties = properties
    }
    public var hasBackground: Bool { model.hasPrefix("lamp") || support.contains("bg_set_rgb") || properties["bg_power"] != nil }
    public var displayName: String { name.isEmpty ? (model == "lamp15" ? "Monitor Light Bar Pro" : "Yeelight " + model) : name }
    public var supportsUDP: Bool { support.contains("udp_sess_new") || support.contains("udp_new") || support.contains("udp_chroma_sess_new") }
    public var defaultChannel: LightChannel { hasBackground ? .background : .main }
    public var segmentCount: Int { max(1, min(1024, Int(properties["strip_length"] ?? "1") ?? 1)) }
}

public struct DeviceAssignment: Codable, Sendable, Hashable {
    public var deviceID: String
    public var enabled: Bool
    public var channel: LightChannel
    public var zone: Int
    public init(deviceID: String, enabled: Bool = true, channel: LightChannel = .main, zone: Int = 0) { self.deviceID = deviceID; self.enabled = enabled; self.channel = channel; self.zone = zone }
}

public struct ScenePreset: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var powerMode: Int
    public var brightness: Int
    public var temperature: Int
    public var rgb: Int
    public var flow: String
}
public struct MusicPalette: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var group: String
    public var colors: [Int]
}
public struct StationPresets: Codable, Sendable {
    public var scenes: [ScenePreset]
    public var palettes: [MusicPalette]
    public var layouts: [ScreenLayout]
    public static func load() throws -> StationPresets {
        let packaged = Bundle.main.url(forResource: "YeelightStationMac_StationCore", withExtension: "bundle")
            .flatMap { Bundle(url: $0) }
        let resources = packaged ?? Bundle.module
        guard let url = resources.url(forResource: "station-presets", withExtension: "json") else { throw StationError.invalidResponse("Bundled Station presets are missing") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

public enum StationError: Error, LocalizedError, Sendable {
    case invalidAddress, invalidResponse(String), timeout(String), device(String), unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a valid IPv4 address."
        case .invalidResponse(let s), .device(let s), .unavailable(let s): return s
        case .timeout(let s): return "Timed out: " + s
        }
    }
}

public enum LightProperties {
    /// Firmware and saved settings are untrusted strings; non-finite values must never reach SwiftUI numeric conversions.
    public static func number(_ value: String?, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value, let parsed = Double(value), parsed.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, parsed))
    }
    public static func validate(_ properties: [String: String]) -> Bool {
        let ranges: [String: ClosedRange<Double>] = ["bright": 0...100, "ct": 0...10000, "rgb": 0...16777215, "hue": 0...360, "sat": 0...100]
        for prefix in ["", "bg_"] {
            for (name, range) in ranges {
                guard let value = properties[prefix + name], !value.isEmpty else { continue }
                guard let parsed = Double(value), parsed.isFinite, range.contains(parsed) else { return false }
            }
        }
        return true
    }
}
