import Foundation
import Darwin

internal enum RealtimeCommands {
    static func frame(device: LightDevice, colors: [RGBColor], channel: LightChannel, brightness: Int) throws -> (String, [JSONValue]) {
        guard !colors.isEmpty, colors.count <= 4096 else {
            throw StationError.invalidResponse("A realtime frame must contain between 1 and 4096 colors.")
        }
        if channel == .main && device.model.lowercased().hasPrefix("lamp") {
            throw StationError.unavailable("This lamp's task light supports color temperature. Select the RGB backlight for realtime color.")
        }
        if channel == .background && !device.hasBackground {
            throw StationError.unavailable("This light does not advertise an RGB backlight.")
        }
        let level = min(100, max(0, brightness))
        let scaled = colors.map { $0.scaled(Double(level) / 100) }
        // One screen-zone color is a whole-backlight intent. A one-element segment
        // array has no established whole-lamp fill semantics; use the scalar path.
        if device.model == "lamp15", channel == .background, colors.count == 1 {
            if device.support.contains("bg_set_scene") {
                return ("bg_set_scene", [.string("color"), .int(level == 0 ? 0 : colors[0].packed), .int(max(1, level)), .int(0), .string("sudden")])
            }
            if device.support.contains("bg_set_rgb") {
                return ("bg_set_rgb", [.int(scaled[0].packed), .string("sudden"), .int(0)])
            }
            throw StationError.unavailable("This lamp does not advertise a whole-backlight RGB command.")
        }
        // These are endpoint-wide segmented methods in the recovered Station path. No bg_/main_ prefix is added.
        if device.support.contains("update_leds") {
            let bytes = scaled.flatMap { [$0.red, $0.green, $0.blue] }
            return ("update_leds", [.string(Data(bytes).base64EncodedString())])
        }
        if device.support.contains("set_segment_rgb") {
            return ("set_segment_rgb", scaled.map { .int($0.packed) })
        }
        let average = RGBColor(red: UInt8(colors.reduce(0) { $0 + Int($1.red) } / colors.count),
                               green: UInt8(colors.reduce(0) { $0 + Int($1.green) } / colors.count),
                               blue: UInt8(colors.reduce(0) { $0 + Int($1.blue) } / colors.count))
        let scene = channel.method("set_scene")
        if device.support.contains(scene) {
            // Recovered UDP scene extension: duration before effect, unlike set_rgb.
            return (scene, [.string("color"), .int(level == 0 ? 0 : average.packed), .int(max(1, level)), .int(0), .string("sudden")])
        }
        let rgb = channel.method("set_rgb")
        if device.support.contains(rgb) {
            return (rgb, [.int(average.scaled(Double(level) / 100).packed), .string("sudden"), .int(0)])
        }
        throw StationError.unavailable("The light does not advertise a realtime RGB command for this channel.")
    }
}

internal extension LightSocketWorker {
    var sessionProtocol: Bool { device.support.contains("udp_sess_new") }
    var creationMethod: String { sessionProtocol ? "udp_sess_new" : "udp_new" }
    var tokenMethod: String { sessionProtocol ? "udp_sess_token" : "udp_token" }
    var keepaliveMethod: String { sessionProtocol ? "udp_sess_keep_alive" : "udp_keep_alive" }

    func startRealtime(channel: LightChannel, cancellation: NetworkCancellation) throws {
        try checkOpen()
        // Validate the channel and encoder before opening a session or changing existing state.
        _ = try RealtimeCommands.frame(device: device, colors: [.black], channel: channel, brightness: 100)
        guard device.support.contains("udp_sess_new") || device.support.contains("udp_new") else {
            throw StationError.unavailable("Realtime requires a supported Yeelight UDP session. Reverse-connect TCP music mode is not implemented for this device.")
        }
        guard configuration.heartbeatInterval.isFinite, configuration.heartbeatInterval > 0,
              configuration.sessionLifetime.isFinite, configuration.sessionLifetime > configuration.heartbeatInterval else {
            throw StationError.unavailable("Invalid UDP heartbeat configuration.")
        }
        if realtimeChannel == channel, udpToken != nil, realtimeError == nil, LightSocket.now - lastSessionReply < configuration.sessionLifetime { return }
        stopRealtime()
        do {
            var address = try LightSocket.address(host: device.host, port: configuration.udpPort)
            udp = try LightSocket.open(type: SOCK_DGRAM)
            // A connected UDP socket filters both source address and source port in the kernel.
            try LightSocket.connect(udp, address: &address, deadline: LightSocket.now + configuration.requestTimeout, cancellation: cancellation)
            try acquireToken(cancellation: cancellation)
            realtimeChannel = channel
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // A short maintenance tick receives ACKs without blocking realtime frames waiting for them.
            let tick = min(0.1, configuration.heartbeatInterval)
            timer.schedule(deadline: .now() + tick, repeating: tick)
            timer.setEventHandler { [weak self] in self?.maintainSession() }
            heartbeat = timer
            timer.resume()
        } catch { stopRealtime(); throw error }
    }

    func sendRealtime(colors: [RGBColor], channel: LightChannel, brightness: Int, cancellation: NetworkCancellation) throws {
        try checkOpen()
        guard realtimeChannel == channel, udp >= 0 else {
            throw StationError.unavailable("Start a realtime session for the selected channel first.")
        }
        let command = try RealtimeCommands.frame(device: device, colors: colors, channel: channel, brightness: brightness)
        try drainUDP()
        if udpToken == nil || LightSocket.now - lastSessionReply >= configuration.sessionLifetime {
            try acquireToken(cancellation: cancellation)
        }
        if let error = realtimeError { realtimeError = nil; throw error }
        guard let token = udpToken else { throw StationError.unavailable("The UDP session has no token.") }
        let data = try LightSocket.packet(id: newID(), method: command.0, params: command.1, token: token)
        guard data.count <= min(65_507, configuration.maximumFrameBytes) else {
            throw StationError.invalidResponse("The realtime frame exceeds the UDP datagram limit.")
        }
        // Firmware only guarantees replies for session/heartbeat packets, so never wait on each frame.
        try LightSocket.write(data, fd: udp, datagram: true, deadline: LightSocket.now + configuration.requestTimeout, cancellation: cancellation)
    }

    func stopRealtime() {
        heartbeat?.setEventHandler {}
        heartbeat?.cancel()
        heartbeat = nil
        if udp >= 0 { Darwin.close(udp); udp = -1 }
        realtimeChannel = nil
        udpToken = nil
        lastSessionReply = 0
        pendingHeartbeat = nil
        lastHeartbeatSent = 0
        realtimeError = nil
        // No session-delete command is documented or recovered. Closing and stopping heartbeats lets it expire.
    }

    private func acquireToken(cancellation: NetworkCancellation) throws {
        udpToken = nil
        lastSessionReply = 0
        pendingHeartbeat = nil
        lastHeartbeatSent = 0
        realtimeError = nil
        // Drain stale packets before sending the new correlation ID.
        try drainUDP()
        let deadline = LightSocket.now + configuration.requestTimeout
        let id = newID()
        try LightSocket.write(LightSocket.packet(id: id, method: creationMethod, params: []), fd: udp,
                              datagram: true, deadline: deadline, cancellation: cancellation)
        while true {
            let response = try readUDP(deadline: deadline, cancellation: cancellation)
            guard response["id"]?.integer == id else { continue }
            if response["error"] != nil { _ = try LightSocket.result(response) }
            guard response["method"]?.text == tokenMethod,
                  case .string(let token)? = response["params"]?.dictionary?["token"],
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, token.utf8.count <= 4096 else {
                throw StationError.invalidResponse("The light returned an invalid UDP session token.")
            }
            udpToken = token
            // Token creation alone is not sufficient: Station gates control on a received heartbeat/property response.
            do { try keepalive(cancellation: cancellation) }
            catch { udpToken = nil; throw error }
            return
        }
    }

    private func sendHeartbeat(cancellation: NetworkCancellation) throws -> Int {
        guard let token = udpToken else { throw StationError.unavailable("The UDP session has no token.") }
        let id = newID()
        let data = try LightSocket.packet(id: id, method: keepaliveMethod,
                                          params: [.string("keeplive_interval"), .int(10)], token: token)
        try LightSocket.write(data, fd: udp, datagram: true, deadline: LightSocket.now + configuration.requestTimeout, cancellation: cancellation)
        lastHeartbeatSent = LightSocket.now
        pendingHeartbeat = (id, lastHeartbeatSent)
        return id
    }

    private func keepalive(cancellation: NetworkCancellation) throws {
        guard let token = udpToken else { throw StationError.unavailable("The UDP session has no token.") }
        let deadline = LightSocket.now + configuration.requestTimeout
        let id = try sendHeartbeat(cancellation: cancellation)
        while true {
            let response = try readUDP(deadline: deadline, cancellation: cancellation)
            guard response["id"]?.integer == id, response["token"]?.text == token else { continue }
            let result = try LightSocket.result(response)
            guard result.values?.first == .string("ok") else { throw StationError.invalidResponse("The light did not acknowledge the UDP heartbeat.") }
            pendingHeartbeat = nil
            lastSessionReply = LightSocket.now
            realtimeError = nil
            return
        }
    }

    private func maintainSession() {
        guard !closed, realtimeChannel != nil, udp >= 0 else { return }
        do {
            try drainUDP()
            let cancellation = NetworkCancellation(timeout: configuration.requestTimeout)
            if udpToken == nil || LightSocket.now - lastSessionReply >= configuration.sessionLifetime {
                try acquireToken(cancellation: cancellation)
            } else if LightSocket.now - lastHeartbeatSent >= configuration.heartbeatInterval {
                // Only startup waits for an ACK. A dropped periodic heartbeat must not pause the frame queue.
                _ = try sendHeartbeat(cancellation: cancellation)
            }
        } catch { realtimeError = error }
    }

    private func readUDP(deadline: TimeInterval, cancellation: NetworkCancellation) throws -> [String: JSONValue] {
        while true {
            try LightSocket.wait(udp, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            try cancellation.check()
            guard LightSocket.now < deadline else { throw StationError.timeout("waiting for a UDP response") }
            if let object = try receiveUDP() { return object }
        }
    }

    private func receiveUDP() throws -> [String: JSONValue]? {
        var bytes = [UInt8](repeating: 0, count: min(65_536, configuration.maximumFrameBytes + 1))
        let count = Darwin.recv(udp, &bytes, bytes.count, 0)
        if count < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            throw LightSocket.failure("Receive UDP session data")
        }
        guard count > 0, count <= configuration.maximumFrameBytes else { throw StationError.invalidResponse("Invalid UDP response size.") }
        return try LightSocket.object(Data(bytes.prefix(count)))
    }

    private func drainUDP() throws {
        // Limit work per frame even if a faulty peer floods the session socket.
        for _ in 0..<64 {
            guard let response = try receiveUDP() else { return }
            guard let token = udpToken, response["token"]?.text == token else { continue }
            if response["error"] != nil { _ = try LightSocket.result(response) }
            // Only a still-outstanding heartbeat can prove freshness. Old frame/heartbeat ACKs
            // must not revive a session after the receive deadline has already expired.
            if let pending = pendingHeartbeat, response["id"]?.integer == pending.id,
               response["result"]?.values?.first == .string("ok"),
               LightSocket.now - pending.sent < configuration.sessionLifetime,
               LightSocket.now - lastSessionReply < configuration.sessionLifetime {
                pendingHeartbeat = nil
                lastSessionReply = LightSocket.now
                realtimeError = nil
            }
        }
    }
}
