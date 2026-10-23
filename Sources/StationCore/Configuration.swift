import Foundation

public struct SavedScene: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var actions: [SavedLightState]
    public init(id: UUID = UUID(), name: String, actions: [SavedLightState]) { self.id = id; self.name = name; self.actions = actions }
}

public struct SavedLightState: Codable, Sendable {
    public var deviceID: String
    public var channel: LightChannel
    public var properties: [String: String]
    public init(deviceID: String, channel: LightChannel, properties: [String: String]) { self.deviceID = deviceID; self.channel = channel; self.properties = properties }
}

public struct StationConfiguration: Codable, Sendable {
    public var version = 1
    public var devices: [LightDevice] = []
    public var assignments: [String: DeviceAssignment] = [:]
    public var savedScenes: [SavedScene] = []
    public var layoutID = "2"
    public var displayID: UInt32? = nil
    public var paletteID = "music-Electronic"
    public var frameInterval = 0.2
    public var syncBrightness = 80.0
    public var sensitivity = 2.0
    public var restoreOnStop = true
    public init() {}
}

public struct ConfigurationStore: Sendable {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YeelightStationMac", isDirectory: true).appendingPathComponent("station.json")
    }
    public func load() throws -> StationConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return StationConfiguration() }
        let config = try JSONDecoder().decode(StationConfiguration.self, from: Data(contentsOf: url))
        guard config.version == 1 else { throw StationError.unavailable("This settings file was created by a newer version of Station.") }
        guard config.devices.count <= 256, config.assignments.count <= 256,
              Set(config.devices.map(\.id)).count == config.devices.count,
              config.devices.allSatisfy({ !$0.id.isEmpty && $0.port > 0 && LightProperties.validate($0.properties) }),
              config.savedScenes.allSatisfy({ $0.actions.count <= 256 && $0.actions.allSatisfy { LightProperties.validate($0.properties) } }),
              config.assignments.values.allSatisfy({ $0.zone >= 0 && $0.zone < 64 }),
              config.savedScenes.count <= 256, config.syncBrightness.isFinite,
              (1...100).contains(config.syncBrightness), config.frameInterval.isFinite,
              (0.08...1).contains(config.frameInterval), config.sensitivity.isFinite,
              (0.25...8).contains(config.sensitivity) else {
            throw StationError.invalidResponse("Saved settings contain invalid values. The file was left unchanged.")
        }
        return config
    }
    public func save(_ configuration: StationConfiguration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: [.atomic])
    }
}
