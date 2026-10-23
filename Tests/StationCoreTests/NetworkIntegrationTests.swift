import XCTest
import Darwin
@testable import StationCore

final class NetworkIntegrationTests: XCTestCase {
    private func config(port: UInt16 = 55444, timeout: TimeInterval = 0.3) -> LightTransportConfiguration {
        .init(requestTimeout: timeout, udpPort: port, heartbeatInterval: 0.05, sessionLifetime: 0.16, minimumControlInterval: 0)
    }
    private func device(port: UInt16 = 55443, support: Set<String> = []) -> LightDevice {
        LightDevice(id: "simulated", name: "Loopback", model: "color4", host: "127.0.0.1", port: port, support: support)
    }

    func testTCPPersistentFramingNotificationsAndDeviceErrors() async throws {
        let completed = expectation(description: "three commands on one TCP connection")
        let server = try TCPProtocolSimulator { fd in
            let first = try SimulatorIO.readLine(fd)
            let firstID = try XCTUnwrap(first["id"]?.integer)
            var data = try SimulatorIO.encode(["method": .string("props"), "params": .object(["power": .string("on")])])
            data.append(try SimulatorIO.encode(["id": .int(firstID + 100), "result": .array([.string("stale")])]))
            data.append(try SimulatorIO.encode(["id": .int(firstID), "result": .array([.string("one")])]))
            try SimulatorIO.write(Data(data.prefix(13)), fd: fd)
            usleep(10_000)
            try SimulatorIO.write(Data(data.dropFirst(13)), fd: fd)
            let second = try SimulatorIO.readLine(fd)
            try SimulatorIO.send(["id": try XCTUnwrap(second["id"]), "error": .object(["code": .int(-1), "message": .string("unsupported")])], fd: fd)
            let third = try SimulatorIO.readLine(fd)
            XCTAssertNotEqual(first["id"], third["id"])
            try SimulatorIO.send(["id": try XCTUnwrap(third["id"]), "result": .array([.string("three")])], fd: fd)
            completed.fulfill()
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config())
        let first = try await connection.request(method: "get_prop", params: [.string("power")])
        XCTAssertEqual(first, .array([.string("one")]))
        do {
            _ = try await connection.request(method: "invalid_command", params: [])
            XCTFail("Device error must throw")
        } catch StationError.device(let message) { XCTAssertTrue(message.contains("unsupported")); XCTAssertTrue(message.contains("-1")) }
        let third = try await connection.request(method: "get_prop", params: [.string("power")])
        XCTAssertEqual(third, .array([.string("three")]))
        await connection.close()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertNil(server.error)
    }

    func testTCPConcurrentRequestsAreNotPipelined() async throws {
        let completed = expectation(description: "serialized")
        let server = try TCPProtocolSimulator { fd in
            let first = try SimulatorIO.readLine(fd)
            var pollfd = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            XCTAssertEqual(Darwin.poll(&pollfd, 1, 30), 0, "Second request must wait for the first acknowledgement")
            try SimulatorIO.send(["id": try XCTUnwrap(first["id"]), "result": .array([try XCTUnwrap(first["method"])])], fd: fd)
            let second = try SimulatorIO.readLine(fd)
            try SimulatorIO.send(["id": try XCTUnwrap(second["id"]), "result": .array([try XCTUnwrap(second["method"])])], fd: fd)
            completed.fulfill()
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config())
        async let first = connection.request(method: "first", params: [])
        async let second = connection.request(method: "second", params: [])
        let results = try await [first, second]
        XCTAssertEqual(results, [.array([.string("first")]), .array([.string("second")])])
        await connection.close()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertNil(server.error)
    }

    func testPropertiesPreserveRequestedOrder() async throws {
        let server = try TCPProtocolSimulator { fd in
            let request = try SimulatorIO.readLine(fd)
            let keys = try XCTUnwrap(request["params"]?.values)
            let values = keys.map { key -> JSONValue in
                if key == .string("power") { return .string("on") }
                if key == .string("bg_bright") { return .string("42") }
                return .string("")
            }
            try SimulatorIO.send(["id": try XCTUnwrap(request["id"]), "result": .array(values)], fd: fd)
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config())
        let values = try await connection.properties()
        XCTAssertEqual(values["power"], "on")
        XCTAssertEqual(values["bg_bright"], "42")
        XCTAssertNil(values["rgb"])
        await connection.close()
    }

    func testFreshPropertiesExcludeUnobservedCachedValuesWithoutClearingTheCache() async throws {
        let server = try TCPProtocolSimulator { fd in
            for index in 0..<3 {
                let request = try SimulatorIO.readLine(fd)
                let keys = try XCTUnwrap(request["params"]?.values)
                let values = keys.map { key -> JSONValue in
                    if key == .string("power") { return .string("on") }
                    if key == .string("bg_bright"), index == 0 { return .string("65") }
                    return .string("")
                }
                try SimulatorIO.send(["id": try XCTUnwrap(request["id"]), "result": .array(values)], fd: fd)
            }
        }
        defer { server.stop() }
        var seeded = device(port: server.port)
        seeded.properties = ["bg_bright": "20", "rgb": "123"]
        let connection = LightConnection(device: seeded, configuration: config())
        let first = try await connection.properties(includeCached: false)
        XCTAssertEqual(first, ["power": "on", "bg_bright": "65"])
        let second = try await connection.properties(includeCached: false)
        XCTAssertEqual(second, ["power": "on"])
        let cached = try await connection.properties()
        XCTAssertEqual(cached["bg_bright"], "65")
        XCTAssertEqual(cached["rgb"], "123")
        await connection.close()
        XCTAssertNil(server.error)
    }

    func testTCPTimeoutAndCancellationAreBounded() async throws {
        let received = expectation(description: "silent peer received request")
        let server = try TCPProtocolSimulator { fd in
            _ = try SimulatorIO.readLine(fd)
            received.fulfill()
            usleep(200_000)
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config(timeout: 0.06))
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await connection.request(method: "get_prop", params: []); XCTFail("Silent peer must time out") }
        catch StationError.timeout { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        await connection.close()
        await fulfillment(of: [received], timeout: 1)

        let cancellable = try TCPProtocolSimulator { fd in _ = try SimulatorIO.readLine(fd); usleep(200_000) }
        defer { cancellable.stop() }
        let second = LightConnection(device: device(port: cancellable.port), configuration: config(timeout: 2))
        let task = Task { try await second.request(method: "get_prop", params: []) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled IO must throw") } catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancellationStart, 0.3)
        await second.close()
    }

    func testQueuedRequestsShareTheSubmissionDeadline() async throws {
        let server = try TCPProtocolSimulator { fd in
            _ = try SimulatorIO.readLine(fd)
            usleep(200_000)
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config(timeout: 0.06))
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do { _ = try await connection.request(method: "get_prop", params: []); return false }
                    catch StationError.timeout { return true }
                    catch { return false }
                }
            }
            var results = [Bool]()
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(timedOut, [Bool](repeating: true, count: 6))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.18)
        await connection.close()
    }

    func testQueuedRequestCancellationReturnsBeforeActiveIOFinishes() async throws {
        let received = expectation(description: "first request active")
        let server = try TCPProtocolSimulator { fd in
            _ = try SimulatorIO.readLine(fd)
            received.fulfill()
            usleep(200_000)
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config(timeout: 2))
        let first = Task { try await connection.request(method: "first", params: []) }
        await fulfillment(of: [received], timeout: 1)
        let queued = Task { try await connection.request(method: "queued", params: []) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled queued request must throw") } catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled active request must throw") } catch is CancellationError { }
        await connection.close()
    }

    func testTCPRejectsMalformedFrames() async throws {
        let server = try TCPProtocolSimulator { fd in
            _ = try SimulatorIO.readLine(fd)
            try SimulatorIO.write(Data("{\"id\":1,\"result\":[\"ok\"]}\n".utf8), fd: fd)
        }
        defer { server.stop() }
        let connection = LightConnection(device: device(port: server.port), configuration: config())
        do { _ = try await connection.request(method: "get_prop", params: []); XCTFail("LF without CR must fail") }
        catch StationError.invalidResponse { }
        await connection.close()
    }

    func testUDPSessionHandshakeTokenFramesAndPeriodicKeepalive() async throws {
        let frame = expectation(description: "base64 RGB frame")
        let heartbeats = expectation(description: "periodic heartbeat")
        heartbeats.expectedFulfillmentCount = 2
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            let method = request["method"]?.text
            if method == "udp_sess_new" {
                XCTAssertEqual(request["params"], .array([])); XCTAssertNil(request["token"])
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"), "params": .object(["token": .string("opaque-simulator-token")])], peer: peer, fd: fd)
            } else if method == "udp_sess_keep_alive" {
                XCTAssertEqual(request["params"], .array([.string("keeplive_interval"), .int(10)]))
                XCTAssertEqual(request["token"], .string("opaque-simulator-token"))
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]), "token": .string("opaque-simulator-token")], peer: peer, fd: fd)
                heartbeats.fulfill()
            } else if method == "update_leds" {
                XCTAssertEqual(request["token"], .string("opaque-simulator-token"))
                XCTAssertEqual(request["params"], .array([.string("/wAAAP8AAAD/")]))
                frame.fulfill()
            } else { XCTFail("Unexpected UDP method \(String(describing: method))") }
        }
        defer { simulator.stop() }
        let connection = LightConnection(device: device(support: ["udp_sess_new", "update_leds"]), configuration: config(port: simulator.port))
        try await connection.startRealtime(channel: .main)
        try await connection.sendRealtime(colors: [RGBColor(packed: 0xFF0000), RGBColor(packed: 0x00FF00), RGBColor(packed: 0x0000FF)], channel: .main)
        await fulfillment(of: [frame, heartbeats], timeout: 1)
        await connection.stopRealtime()
        let count = simulator.messages.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(simulator.messages.count, count, "Stop must cancel heartbeats")
        do { try await connection.sendRealtime(colors: [.black], channel: .main); XCTFail("Stopped session must not send") }
        catch StationError.unavailable { }
        await connection.close()
        XCTAssertNil(simulator.error)
    }

    func testUDPLegacyHandshakeAndBacklightMethod() async throws {
        let frame = expectation(description: "legacy backlight")
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            switch request["method"]?.text {
            case "udp_new":
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_token"), "params": .object(["token": .string("legacy")])], peer: peer, fd: fd)
            case "udp_keep_alive":
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]), "token": .string("legacy")], peer: peer, fd: fd)
            case "bg_set_rgb":
                XCTAssertEqual(request["params"], .array([.int(0x7F0000), .string("sudden"), .int(0)]))
                XCTAssertEqual(request["token"], .string("legacy")); frame.fulfill()
            default: XCTFail("Wrong legacy UDP method")
            }
        }
        defer { simulator.stop() }
        let lamp = LightDevice(id: "lamp", name: "", model: "lamp15", host: "127.0.0.1", support: ["udp_new", "bg_set_rgb"])
        let connection = LightConnection(device: lamp, configuration: config(port: simulator.port))
        try await connection.startRealtime(channel: .background)
        try await connection.sendRealtime(colors: [RGBColor(packed: 0xFF0000)], channel: .background, brightness: 50)
        await fulfillment(of: [frame], timeout: 1)
        await connection.close()
        XCTAssertNil(simulator.error)
    }

    func testUDPReacquiresAfterHeartbeatLoss() async throws {
        let renewed = expectation(description: "token was reacquired")
        let frame = expectation(description: "new token frame")
        var creations = 0
        var firstHeartbeat = true
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            if request["method"] == .string("udp_sess_new") {
                creations += 1
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"), "params": .object(["token": .string("token\(creations)")])], peer: peer, fd: fd)
            } else if request["method"] == .string("udp_sess_keep_alive") {
                if firstHeartbeat || creations > 1 {
                    firstHeartbeat = false
                    try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]), "token": .string("token\(creations)")], peer: peer, fd: fd)
                    if creations == 2 { renewed.fulfill() }
                }
            } else if request["method"] == .string("set_segment_rgb") {
                XCTAssertEqual(request["token"], .string("token2")); frame.fulfill()
            }
        }
        defer { simulator.stop() }
        let connection = LightConnection(device: device(support: ["udp_sess_new", "set_segment_rgb"]), configuration: config(port: simulator.port, timeout: 0.03))
        try await connection.startRealtime(channel: .main)
        await fulfillment(of: [renewed], timeout: 1)
        try await connection.sendRealtime(colors: [RGBColor(packed: 0x112233)], channel: .main)
        await fulfillment(of: [frame], timeout: 1)
        await connection.close()
        XCTAssertNil(simulator.error)
    }

    func testUDPStaleAcknowledgementCannotReviveExpiredSession() async throws {
        let frame = expectation(description: "renewed token frame")
        var creations = 0
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            if request["method"] == .string("udp_sess_new") {
                creations += 1
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"),
                                         "params": .object(["token": .string("token\(creations)")])], peer: peer, fd: fd)
            } else if request["method"] == .string("udp_sess_keep_alive") {
                // Acknowledge the startup heartbeat, drop the next one, then accept the new session.
                if creations > 1 || request["id"] == .int(2) {
                    try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]),
                                             "token": .string("token\(creations)")], peer: peer, fd: fd)
                }
            } else {
                XCTAssertEqual(request["token"], .string("token2"))
                frame.fulfill()
            }
        }
        defer { simulator.stop() }
        var options = config(port: simulator.port, timeout: 0.04)
        options.heartbeatInterval = 0.04
        options.sessionLifetime = 0.08
        let worker = LightSocketWorker(device: device(support: ["udp_sess_new", "set_rgb"]), configuration: options)
        try await worker.perform { try $0.startRealtime(channel: .main, cancellation: $1) }
        // Pause autonomous maintenance to isolate the frame-triggered expiry path. Otherwise
        // the timer could renew first and make a stale-ACK regression pass for the wrong reason.
        await worker.cleanup {
            $0.heartbeat?.setEventHandler {}
            $0.heartbeat?.cancel()
            $0.heartbeat = nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(simulator.messages.filter { $0["method"] == .string("udp_sess_new") }.count, 1,
                       "Expiry must precede replay without an automatic renewal")
        try simulator.replay(["id": .int(2), "result": .array([.string("ok")]), "token": .string("token1")])
        try await worker.perform { try $0.sendRealtime(colors: [.black], channel: .main, brightness: 100, cancellation: $1) }
        await fulfillment(of: [frame], timeout: 1)
        XCTAssertEqual(simulator.messages.filter { $0["method"] == .string("udp_sess_new") }.count, 2)
        await worker.cleanup { $0.dispose() }
        XCTAssertNil(simulator.error)
    }

    func testSlowTCPControlDoesNotBlockUDPFrames() async throws {
        let controlReceived = expectation(description: "slow control")
        let frame = expectation(description: "independent realtime frame")
        let tcp = try TCPProtocolSimulator { fd in
            _ = try SimulatorIO.readLine(fd)
            controlReceived.fulfill()
            usleep(200_000)
        }
        defer { tcp.stop() }
        let udp = try UDPProtocolSimulator { request, peer, fd in
            if request["method"] == .string("udp_sess_new") {
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"),
                                         "params": .object(["token": .string("independent")])], peer: peer, fd: fd)
            } else if request["method"] == .string("udp_sess_keep_alive") {
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]),
                                         "token": .string("independent")], peer: peer, fd: fd)
            } else { frame.fulfill() }
        }
        defer { udp.stop() }
        let connection = LightConnection(device: device(port: tcp.port, support: ["udp_sess_new", "set_rgb"]), configuration: config(port: udp.port))
        try await connection.startRealtime(channel: .main)
        let slow = Task { try await connection.request(method: "get_prop", params: []) }
        await fulfillment(of: [controlReceived], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        try await connection.sendRealtime(colors: [.black], channel: .main)
        await fulfillment(of: [frame], timeout: 0.1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1)
        slow.cancel()
        do { _ = try await slow.value; XCTFail("Cancelled control must throw") } catch is CancellationError { }
        await connection.close()
    }

    func testDroppedPeriodicHeartbeatDoesNotPauseFrames() async throws {
        let droppedHeartbeat = expectation(description: "periodic heartbeat dropped")
        let frame = expectation(description: "frame still streams")
        var heartbeats = 0
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            if request["method"] == .string("udp_sess_new") {
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"),
                                         "params": .object(["token": .string("streaming")])], peer: peer, fd: fd)
            } else if request["method"] == .string("udp_sess_keep_alive") {
                heartbeats += 1
                if heartbeats == 1 {
                    try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]),
                                             "token": .string("streaming")], peer: peer, fd: fd)
                } else if heartbeats == 2 { droppedHeartbeat.fulfill() }
            } else { frame.fulfill() }
        }
        defer { simulator.stop() }
        var options = config(port: simulator.port)
        options.heartbeatInterval = 0.04
        options.sessionLifetime = 0.2
        let connection = LightConnection(device: device(support: ["udp_sess_new", "set_rgb"]), configuration: options)
        try await connection.startRealtime(channel: .main)
        await fulfillment(of: [droppedHeartbeat], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        try await connection.sendRealtime(colors: [.black], channel: .main)
        await fulfillment(of: [frame], timeout: 0.1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1)
        await connection.close()
    }

    func testUDPDoesNotBecomeReadyWithoutAuthenticatedHeartbeat() async throws {
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            if request["method"] == .string("udp_sess_new") {
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"), "params": .object(["token": .string("correct")])], peer: peer, fd: fd)
            } else {
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]), "token": .string("wrong-token")], peer: peer, fd: fd)
            }
        }
        defer { simulator.stop() }
        let connection = LightConnection(device: device(support: ["udp_sess_new", "set_rgb"]), configuration: config(port: simulator.port, timeout: 0.05))
        do { try await connection.startRealtime(channel: .main); XCTFail("Wrong-token heartbeat must not report ready") }
        catch StationError.timeout { }
        do { try await connection.sendRealtime(colors: [.black], channel: .main); XCTFail("Failed startup must not leave session active") }
        catch StationError.unavailable { }
        await connection.close()
    }

    func testUDPFiltersPacketsFromWrongSourcePort() async throws {
        let frame = expectation(description: "trusted token")
        let simulator = try UDPProtocolSimulator { request, peer, fd in
            if request["method"] == .string("udp_sess_new") {
                let spoof = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
                defer { Darwin.close(spoof) }
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"), "params": .object(["token": .string("spoofed")])], peer: peer, fd: spoof)
                usleep(5_000)
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "method": .string("udp_sess_token"), "params": .object(["token": .string("trusted")])], peer: peer, fd: fd)
            } else if request["method"] == .string("udp_sess_keep_alive") {
                XCTAssertEqual(request["token"], .string("trusted"))
                try SimulatorIO.sendUDP(["id": try XCTUnwrap(request["id"]), "result": .array([.string("ok")]), "token": .string("trusted")], peer: peer, fd: fd)
            } else { XCTAssertEqual(request["token"], .string("trusted")); frame.fulfill() }
        }
        defer { simulator.stop() }
        let connection = LightConnection(device: device(support: ["udp_sess_new", "set_rgb"]), configuration: config(port: simulator.port))
        try await connection.startRealtime(channel: .main)
        try await connection.sendRealtime(colors: [.black], channel: .main)
        await fulfillment(of: [frame], timeout: 1)
        await connection.close()
    }

    func testTCPOnlyRealtimeAndClosedConnectionsFailClearly() async throws {
        let connection = LightConnection(device: device(support: ["set_rgb", "set_music"]), configuration: config())
        do { try await connection.startRealtime(channel: .main); XCTFail("TCP fallback must not fake readiness") }
        catch StationError.unavailable(let message) { XCTAssertTrue(message.contains("music mode")) }
        await connection.close()
        do { _ = try await connection.request(method: "get_prop", params: []); XCTFail("Closed connection must fail") }
        catch StationError.unavailable { }
    }
}

private enum SimulatorIO {
    static func bindSocket(type: Int32) throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, type, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return (fd, UInt16(bigEndian: address.sin_port))
    }
    static func encode(_ object: [String: JSONValue]) throws -> Data {
        var data = try JSONEncoder().encode(JSONValue.object(object)); data.append(contentsOf: [13, 10]); return data
    }
    static func send(_ object: [String: JSONValue], fd: Int32) throws { try write(encode(object), fd: fd) }
    static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                guard sent > 0 else { throw POSIXError(.EIO) }; offset += sent
            }
        }
    }
    static func readLine(_ fd: Int32) throws -> [String: JSONValue] {
        var data = Data()
        while data.count < 65_536 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 1000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            var byte: UInt8 = 0
            guard Darwin.recv(fd, &byte, 1, 0) == 1 else { throw POSIXError(.EIO) }
            data.append(byte)
            if byte == 10 {
                guard data.count >= 2, data[data.count - 2] == 13 else { throw POSIXError(.EPROTO) }
                return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).dictionary)
            }
        }
        throw POSIXError(.EMSGSIZE)
    }
    static func sendUDP(_ object: [String: JSONValue], peer: sockaddr_in, fd: Int32) throws {
        let data = try encode(object)
        var peer = peer
        let result = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard result == data.count else { throw POSIXError(.EIO) }
    }
}

private final class TCPProtocolSimulator: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let queue = DispatchQueue(label: "test.tcp.simulator")
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    init(handler: @escaping (Int32) throws -> Void) throws {
        (fd, port) = try SimulatorIO.bindSocket(type: SOCK_STREAM)
        guard listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        queue.async { [self] in
            do {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 2000) > 0 else { throw POSIXError(.ETIMEDOUT) }
                let peer = Darwin.accept(fd, nil, nil)
                guard peer >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(peer) }
                var one: Int32 = 1
                _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                try handler(peer)
            } catch { lock.lock(); storedError = error; lock.unlock() }
        }
    }
    func stop() { queue.sync { _ = Darwin.close(fd) } }
}

private final class UDPProtocolSimulator: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let queue = DispatchQueue(label: "test.udp.simulator")
    private let lock = NSLock()
    private var stopped = false
    private var storedError: Error?
    private var storedMessages = [[String: JSONValue]]()
    private var lastPeer: sockaddr_in?
    var messages: [[String: JSONValue]] { lock.lock(); defer { lock.unlock() }; return storedMessages }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    init(handler: @escaping ([String: JSONValue], sockaddr_in, Int32) throws -> Void) throws {
        (fd, port) = try SimulatorIO.bindSocket(type: SOCK_DGRAM)
        queue.async { [self] in
            while true {
                lock.lock(); let shouldStop = stopped; lock.unlock(); if shouldStop { return }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 10) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 65_536)
                var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &size) } }
                do {
                    guard count > 0 else { throw POSIXError(.EIO) }
                    XCTAssertEqual(Array(bytes.prefix(count).suffix(2)), [13, 10], "UDP packets must use recovered CRLF framing")
                    let request = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(bytes.prefix(count))).dictionary)
                    lock.lock(); storedMessages.append(request); lastPeer = peer; lock.unlock()
                    try handler(request, peer, fd)
                } catch { lock.lock(); storedError = error; lock.unlock(); return }
            }
        }
    }
    func replay(_ object: [String: JSONValue]) throws {
        lock.lock(); let peer = lastPeer; lock.unlock()
        guard let peer else { throw POSIXError(.ENOTCONN) }
        try SimulatorIO.sendUDP(object, peer: peer, fd: fd)
    }
    func stop() { lock.lock(); stopped = true; lock.unlock(); queue.sync { _ = Darwin.close(fd) } }
}
