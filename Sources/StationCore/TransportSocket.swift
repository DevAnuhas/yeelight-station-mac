import Foundation
import Darwin

// All socket IO runs on LightSocketWorker's serial DispatchQueue, never on the cooperative executor.
internal final class NetworkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: TimeInterval?
    init(timeout: TimeInterval? = nil) {
        deadline = timeout.flatMap { $0.isFinite && $0 > 0 ? LightSocket.now + $0 : nil }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
        if let deadline, LightSocket.now >= deadline { throw StationError.timeout("waiting for the network operation") }
    }
}

internal enum LightSocket {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func address(host: String, port: UInt16) throws -> sockaddr_in {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard port > 0, parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) && (UInt8($0) != nil) }),
              let first = UInt8(parts[0]), first > 0, first < 224,
              host != "255.255.255.255" else { throw StationError.invalidAddress }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { throw StationError.invalidAddress }
        return address
    }

    static func open(type: Int32) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, type, 0)
        guard fd >= 0 else { throw failure("Create socket") }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw failure("Configure socket") }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func connect(_ fd: Int32, address: inout sockaddr_in, deadline: TimeInterval, cancellation: NetworkCancellation) throws {
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status == 0 { return }
        guard errno == EINPROGRESS || errno == EWOULDBLOCK else { throw failure("Connect") }
        try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw failure("Connect") }
        if error != 0 { throw failure("Connect", code: error) }
    }

    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval, cancellation: NetworkCancellation) throws {
        while true {
            try cancellation.check()
            let remaining = deadline - now
            guard remaining > 0 else { throw StationError.timeout("waiting for the light") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(50, max(1, remaining * 1000))))
            if result < 0 {
                if errno == EINTR { continue }
                throw failure("Wait for socket")
            }
            if result == 0 { continue }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw StationError.unavailable("The light closed its connection.")
            }
        }
    }

    static func write(_ data: Data, fd: Int32, datagram: Bool = false, deadline: TimeInterval, cancellation: NetworkCancellation) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try cancellation.check()
                guard now < deadline else { throw StationError.timeout("sending to the light") }
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count > 0 {
                    if datagram && count != bytes.count { throw StationError.unavailable("Incomplete UDP datagram.") }
                    offset += count
                } else if count < 0 && (errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR) {
                    try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
                } else { throw failure("Send to light") }
            }
        }
    }

    static func failure(_ operation: String, code: Int32 = errno) -> StationError {
        .unavailable("\(operation): \(String(cString: strerror(code))).")
    }

    static func packet(id: Int, method: String, params: [JSONValue], token: String? = nil) throws -> Data {
        var object: [String: JSONValue] = ["id": .int(id), "method": .string(method), "params": .array(params)]
        if let token { object["token"] = .string(token) }
        var data = try JSONEncoder().encode(JSONValue.object(object))
        data.append(contentsOf: [13, 10])
        return data
    }

    static func object(_ data: Data) throws -> [String: JSONValue] {
        do {
            guard let object = try JSONDecoder().decode(JSONValue.self, from: data).dictionary else {
                throw StationError.invalidResponse("The light returned a JSON value instead of an object.")
            }
            return object
        } catch let error as StationError { throw error }
        catch { throw StationError.invalidResponse("The light returned malformed JSON.") }
    }

    static func result(_ object: [String: JSONValue]) throws -> JSONValue {
        if let error = object["error"] {
            guard let details = error.dictionary else { throw StationError.invalidResponse("Malformed device error.") }
            let code = details["code"]?.integer.map { " (\($0))" } ?? ""
            throw StationError.device((details["message"]?.text ?? "The light rejected the command") + code)
        }
        guard let result = object["result"], result.values != nil else {
            throw StationError.invalidResponse("The light's response has no result array.")
        }
        return result
    }
}
