import Darwin
import Foundation
import StationCore

@main
struct StationCLI {
    static let usage = """
    stationctl discover [IP]                 Discover lights (optional unicast IP).
    stationctl probe IP [--model lamp15]     Read current properties; does not change the light.
    stationctl power IP on|off [--background]
    stationctl rgb IP RRGGBB [--background]
    stationctl brightness IP 1...100 [--background]
    stationctl temperature IP 1700...6500
    stationctl stream-test IP --apply [--seconds 8]  Test lamp15 RGB output, then restore it.

    Controls use TCP and wait for the device acknowledgement. Use --model lamp15
    for a Light Bar Pro when discovery cannot supply a model. --background selects
    the RGB backlight; the default channel is the main light.
    """
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, command != "--help", command != "help" else { print(usage); return }
        do {
            if command == "discover" {
                let found = try await YeelightDiscovery.scan(timeout: 3, host: args.dropFirst().first)
                try printJSON(found); return
            }
            guard args.count >= 2 else { throw StationError.invalidResponse(usage) }
            let host = args[1]
            let discovered = try await YeelightDiscovery.scan(timeout: 1, host: host).first
            let modelIndex = args.firstIndex(of: "--model")
            let model = modelIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "unknown"
            let device = discovered ?? LightDevice(id: "manual-" + host, name: "", model: model, host: host)
            let connection = LightConnection(device: device)
            do {
                if command == "stream-test" {
                    guard args.contains("--apply") else { throw StationError.invalidResponse("stream-test briefly changes the backlight. Pass --apply to run it and restore its settings afterward.") }
                    let index = args.firstIndex(of: "--seconds")
                    let seconds = index.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 8
                    guard (2...20).contains(seconds) else { throw StationError.invalidResponse("Test duration must be 2...20 seconds.") }
                    try await streamTest(connection, device: device, seconds: seconds)
                } else if command == "probe" {
                    let properties = try await connection.properties()
                    try printJSON(properties)
                } else {
                    guard args.count >= 3 else { throw StationError.invalidResponse(usage) }
                    let channel: LightChannel = args.contains("--background") ? .background : .main
                    let value = args[2]
                    let operation: (String, [JSONValue])
                    switch command {
                    case "power":
                        guard ["on", "off"].contains(value) else { throw StationError.invalidResponse("Power must be on or off.") }
                        operation = LightCommands.power(value == "on", channel: channel)
                    case "rgb":
                        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
                        guard hex.count == 6, let rgb = Int(hex, radix: 16) else { throw StationError.invalidResponse("RGB must contain exactly six hex digits, for example FF5500.") }
                        operation = LightCommands.color(RGBColor(packed: rgb), channel: channel)
                    case "brightness":
                        guard let bright = Int(value), (1...100).contains(bright) else { throw StationError.invalidResponse("Brightness must be 1...100.") }
                        operation = LightCommands.brightness(bright, channel: channel)
                    case "temperature":
                        guard let temperature = Int(value), (1700...6500).contains(temperature) else { throw StationError.invalidResponse("Temperature must be 1700...6500 K.") }
                        operation = LightCommands.temperature(temperature, channel: channel)
                    default: throw StationError.invalidResponse(usage)
                    }
                    let result = try await connection.request(method: operation.0, params: operation.1)
                    try printJSON(result)
                }
                await connection.close()
            } catch { await connection.close(); throw error }
        } catch {
            FileHandle.standardError.write(Data(("stationctl: " + error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    static func streamTest(_ connection: LightConnection, device: LightDevice, seconds: Int) async throws {
        guard !device.support.isEmpty else { throw StationError.unavailable("Discovery returned no device capabilities. Allow local-network/UDP access for stationctl and discover the light before running a realtime test.") }
        guard device.model == "lamp15" else { throw StationError.unavailable("This test is scoped to the Monitor Light Bar Pro (lamp15).") }
        let baseline = try await connection.properties()
        guard baseline["flowing"] != "1", baseline["bg_flowing"] != "1" else { throw StationError.unavailable("Stop existing color flows before this static-state restoration test.") }
        let palette = [RGBColor(packed: 0x3366ff), RGBColor(packed: 0x33cc66), RGBColor(packed: 0xaa44ee)]
        var testError: Error?
        do {
            try await connection.startRealtime(channel: .background)
            let on = LightCommands.power(true, channel: .background)
            _ = try await connection.request(method: on.0, params: on.1)
            print("Streaming blue, green and purple across the backlight at 30% for \(seconds) seconds.")
            for frame in 0..<(seconds * 10) {
                try await connection.sendRealtime(colors: [palette[(frame / 20) % palette.count]], channel: .background, brightness: 30)
                try await Task.sleep(for: .milliseconds(100))
            }
            let state = try await connection.properties()
            let expected = palette[((seconds * 10 - 1) / 20) % palette.count].packed
            guard state["bg_rgb"] == String(expected), state["bg_bright"] == "30",
                  ["power", "bright", "ct"].allSatisfy({ state[$0] == baseline[$0] }) else {
                throw StationError.invalidResponse("Realtime read-back did not match the expected backlight color/brightness or the task light changed.")
            }
            print("Realtime color and brightness read-back matched; task light unchanged.")
        } catch { testError = error }
        await connection.stopRealtime()
        if let rgb = baseline["bg_rgb"].flatMap(Int.init), let brightness = baseline["bg_bright"].flatMap(Int.init) {
            _ = try await connection.request(method: "bg_set_scene", params: [.string("color"), .int(rgb), .int(brightness)])
        }
        if let power = baseline["bg_power"] {
            let restore = LightCommands.power(power == "on", channel: .background)
            _ = try await connection.request(method: restore.0, params: restore.1)
        }
        let restored = try await connection.properties()
        guard ["power", "bright", "ct", "bg_power", "bg_bright", "bg_rgb"].allSatisfy({ restored[$0] == baseline[$0] }) else {
            throw StationError.invalidResponse("The test finished, but original light settings could not be verified. Check the light.")
        }
        print("Original static settings restored and verified.")
        if let testError { throw testError }
    }
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }
}
