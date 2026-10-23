import Foundation
import Darwin

/// One persistent, serialized control connection and (when supported) one authenticated UDP session.
public actor LightConnection {
    private let worker: LightSocketWorker
    private let realtimeWorker: LightSocketWorker

    public init(device: LightDevice) {
        worker = LightSocketWorker(device: device, configuration: .init())
        realtimeWorker = LightSocketWorker(device: device, configuration: .init())
    }
    internal init(device: LightDevice, configuration: LightTransportConfiguration) {
        worker = LightSocketWorker(device: device, configuration: configuration)
        realtimeWorker = LightSocketWorker(device: device, configuration: configuration)
    }

    public func request(method: String, params: [JSONValue]) async throws -> JSONValue {
        try await worker.perform { try $0.request(method: method, params: params, cancellation: $1) }
    }

    /// Empty protocol values mean unsupported/unavailable. Callers reconciling
    /// acknowledged edits can request only observations from this reply.
    public func properties(includeCached: Bool = true) async throws -> [String: String] {
        try await worker.perform { worker, cancellation in
            let keys = ["power", "bright", "ct", "rgb", "hue", "sat", "color_mode", "flowing", "delayoff", "music_on", "name",
                        "bg_power", "bg_bright", "bg_ct", "bg_rgb", "bg_hue", "bg_sat", "bg_color_mode",
                        "model", "fw_ver", "strip_length", "bg_lmode", "bg_proact", "bg_flowing", "flow_params", "bg_flow_params"]
            let response = try worker.request(method: "get_prop", params: keys.map(JSONValue.string), cancellation: cancellation)
            guard let values = response.values, values.count == keys.count else {
                throw StationError.invalidResponse("get_prop returned the wrong number of properties.")
            }
            var observed: [String: String] = [:]
            for (key, value) in zip(keys, values) {
                guard let text = value.text else { throw StationError.invalidResponse("get_prop returned a non-scalar property.") }
                // Unsupported properties are empty strings in the LAN protocol.
                if !text.isEmpty { worker.cachedProperties[key] = text; observed[key] = text }
            }
            return includeCached ? worker.cachedProperties : observed
        }
    }

    public func startRealtime(channel: LightChannel) async throws {
        try await realtimeWorker.perform { try $0.startRealtime(channel: channel, cancellation: $1) }
    }

    public func sendRealtime(colors: [RGBColor], channel: LightChannel, brightness: Int = 100) async throws {
        try await realtimeWorker.perform { try $0.sendRealtime(colors: colors, channel: channel, brightness: brightness, cancellation: $1) }
    }

    public func stopRealtime() async { await realtimeWorker.cleanup { $0.stopRealtime() } }
    public func close() async {
        async let controls: Void = worker.cleanup { $0.dispose(); $0.closed = true }
        async let realtime: Void = realtimeWorker.cleanup { $0.dispose(); $0.closed = true }
        _ = await (controls, realtime)
    }
}

/// Internal injection is deliberately separate from the public API so simulations never use lamp ports.
internal struct LightTransportConfiguration: Sendable {
    var requestTimeout: TimeInterval = 3
    var udpPort: UInt16 = 55444
    var heartbeatInterval: TimeInterval = 5
    var sessionLifetime: TimeInterval = 10
    var minimumControlInterval: TimeInterval = 1.05
    var maximumFrameBytes: Int = 65_536
}

internal final class LightSocketWorker: @unchecked Sendable {
    let device: LightDevice
    let configuration: LightTransportConfiguration
    let queue = DispatchQueue(label: "station.light.socket", qos: .userInitiated)
    var closed = false
    var tcp: Int32 = -1
    var tcpBuffer = Data()
    var udp: Int32 = -1
    var nextID = 0
    var cachedProperties: [String: String]
    var lastControlSent: TimeInterval = 0
    var realtimeChannel: LightChannel?
    var udpToken: String?
    var lastSessionReply: TimeInterval = 0
    var pendingHeartbeat: (id: Int, sent: TimeInterval)?
    var lastHeartbeatSent: TimeInterval = 0
    var heartbeat: DispatchSourceTimer?
    var realtimeError: Error?

    init(device: LightDevice, configuration: LightTransportConfiguration) {
        self.device = device
        self.configuration = configuration
        cachedProperties = device.properties
    }

    deinit { dispose() }

    func perform<T>(_ operation: @escaping (LightSocketWorker, NetworkCancellation) throws -> T) async throws -> T {
        // The deadline starts at submission, so a backlog cannot turn bounded IO into an unbounded wait.
        let cancellation = NetworkCancellation(timeout: configuration.requestTimeout)
        let completion = PendingNetworkOperation<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.attach(continuation)
                queue.async {
                    do { try cancellation.check(); completion.finish(.success(try operation(self, cancellation))) }
                    catch { completion.finish(.failure(error)) }
                }
            }
        } onCancel: {
            cancellation.cancel()
            // Resume immediately even when the operation is waiting behind another socket request.
            completion.finish(.failure(CancellationError()))
        }
    }

    func cleanup(_ operation: @escaping (LightSocketWorker) -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async { operation(self); continuation.resume() }
        }
    }

    func newID() -> Int { nextID = nextID == Int32.max ? 1 : nextID + 1; return nextID }

    func checkOpen() throws {
        guard !closed else { throw StationError.unavailable("This light connection is closed.") }
        guard configuration.requestTimeout.isFinite, configuration.requestTimeout > 0 else {
            throw StationError.unavailable("The network timeout must be positive and finite.")
        }
    }

    func request(method: String, params: [JSONValue], cancellation: NetworkCancellation) throws -> JSONValue {
        try checkOpen()
        guard !method.isEmpty, method.utf8.count <= 80,
              method.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
            throw StationError.invalidResponse("Invalid LAN command name.")
        }
        let id = newID()
        let data = try LightSocket.packet(id: id, method: method, params: params)
        guard data.count <= configuration.maximumFrameBytes else { throw StationError.invalidResponse("LAN command is too large.") }
        // The public protocol limits each TCP connection to 60 commands/minute.
        while LightSocket.now - lastControlSent < configuration.minimumControlInterval {
            try cancellation.check()
            Thread.sleep(forTimeInterval: max(0.001, min(0.02, configuration.minimumControlInterval - (LightSocket.now - lastControlSent))))
        }
        let deadline = LightSocket.now + configuration.requestTimeout
        do {
            if tcp < 0 {
                var address = try LightSocket.address(host: device.host, port: device.port)
                tcp = try LightSocket.open(type: SOCK_STREAM)
                try LightSocket.connect(tcp, address: &address, deadline: deadline, cancellation: cancellation)
            }
            try LightSocket.write(data, fd: tcp, deadline: deadline, cancellation: cancellation)
            lastControlSent = LightSocket.now
            while true {
                try cancellation.check()
                guard LightSocket.now < deadline else { throw StationError.timeout("waiting for \(method) acknowledgement") }
                let object = try LightSocket.object(readTCPLine(deadline: deadline, cancellation: cancellation))
                if object["method"]?.text == "props", let props = object["params"]?.dictionary {
                    for (key, value) in props { if let text = value.text { cachedProperties[key] = text } }
                    continue
                }
                guard object["id"]?.integer == id else { continue }
                return try LightSocket.result(object)
            }
        } catch let error as StationError {
            // A negative acknowledgement is a valid response; preserve the working socket.
            if case .device = error { throw error }
            closeTCP()
            throw error
        } catch {
            closeTCP()
            throw error
        }
    }

    private func readTCPLine(deadline: TimeInterval, cancellation: NetworkCancellation) throws -> Data {
        while true {
            try cancellation.check()
            guard LightSocket.now < deadline else { throw StationError.timeout("reading a LAN response") }
            if let newline = tcpBuffer.firstIndex(of: 10) {
                guard newline > tcpBuffer.startIndex, tcpBuffer[newline - 1] == 13 else {
                    throw StationError.invalidResponse("LAN responses must end with CRLF.")
                }
                let line = Data(tcpBuffer[..<(newline - 1)])
                tcpBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                return line
            }
            guard tcpBuffer.count < configuration.maximumFrameBytes else {
                throw StationError.invalidResponse("The LAN response exceeded the frame size limit.")
            }
            try LightSocket.wait(tcp, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            var bytes = [UInt8](repeating: 0, count: min(8192, configuration.maximumFrameBytes - tcpBuffer.count))
            let count = Darwin.recv(tcp, &bytes, bytes.count, 0)
            if count > 0 { tcpBuffer.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw StationError.unavailable("The light closed its connection before acknowledging the command.") }
            else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { throw LightSocket.failure("Read from light") }
        }
    }

    func closeTCP() {
        if tcp >= 0 { Darwin.close(tcp); tcp = -1 }
        tcpBuffer.removeAll(keepingCapacity: false)
    }

    func dispose() { stopRealtime(); closeTCP() }
}

/// Cancellation can arrive before attachment, while queued, or during IO. Resume exactly once.
private final class PendingNetworkOperation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false
    private var pendingResult: Result<Value, Error>?

    func attach(_ value: CheckedContinuation<Value, Error>) {
        lock.lock()
        if completed {
            let result = pendingResult!
            pendingResult = nil
            lock.unlock()
            value.resume(with: result)
        } else {
            continuation = value
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let value = continuation
        continuation = nil
        if value == nil { pendingResult = result }
        lock.unlock()
        value?.resume(with: result)
    }
}
