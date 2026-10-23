import Darwin
import Foundation
import StationCore

/// An acknowledged LAN peer on an ephemeral loopback port. A held response does
/// not block its event loop, so unexpected writes and reconnects remain visible.
final class LoopbackLight: @unchecked Sendable {
    struct Request {
        let method: String
        let params: [JSONValue]
    }

    private struct Peer {
        let fd: Int32
        var buffer = Data()
    }

    let port: UInt16
    private let listener: Int32
    private let queue = DispatchQueue(label: "test.station-app.light")
    private let lock = NSLock()
    private var stopped = false
    private var held: (fd: Int32, request: [String: JSONValue])?
    private var releaseHeld = false
    private var methodsToHold: [String]
    private var recorded = [Request]()
    private var accepted = 0
    private var active = 0
    private var failure: Error?

    static let properties = [
        "power": "on", "bright": "80", "ct": "4000", "rgb": "16777215",
        "hue": "0", "sat": "0", "color_mode": "2", "flowing": "0",
        "delayoff": "0", "music_on": "0", "name": "Loopback light",
        "bg_power": "on", "bg_bright": "65", "bg_ct": "4000",
        "bg_rgb": "205", "bg_hue": "240", "bg_sat": "100", "bg_color_mode": "1"
    ]

    var requests: [Request] { synchronized { recorded } }
    var connectionCount: Int { synchronized { accepted } }
    var activeConnectionCount: Int { synchronized { active } }
    var error: Error? { synchronized { failure } }

    init(holdFirstMethod: String? = nil) throws {
        methodsToHold = holdFirstMethod.map { [$0] } ?? []
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        queue.async { [self] in serve() }
    }

    func acknowledgeHeldRequest() { synchronized { releaseHeld = true } }
    func holdNextRequest(method: String) { synchronized { methodsToHold.append(method) } }

    func stop() {
        synchronized { stopped = true }
        queue.sync { }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func serve() {
        var peers = [Peer]()
        defer {
            for peer in peers { Darwin.close(peer.fd) }
            Darwin.close(listener)
            synchronized { active = 0 }
        }
        do {
            while !synchronized({ stopped }) {
                if let pending = synchronized({ () -> (fd: Int32, request: [String: JSONValue])? in
                    guard releaseHeld else { return nil }
                    releaseHeld = false
                    defer { held = nil }
                    return held
                }), peers.contains(where: { $0.fd == pending.fd }) {
                    try respond(to: pending.request, fd: pending.fd)
                }
                var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
                descriptors += peers.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
                let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), 10)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.EIO)
                }
                // The descriptor snapshot predates newly accepted peers.
                for index in peers.indices.reversed() where descriptors[index + 1].revents != 0 {
                    if try !receive(from: &peers[index]) {
                        let fd = peers.remove(at: index).fd
                        Darwin.close(fd)
                        synchronized {
                            active -= 1
                            if held?.fd == fd { held = nil }
                        }
                    }
                }
                if descriptors[0].revents & Int16(POLLIN) != 0 {
                    let fd = Darwin.accept(listener, nil, nil)
                    guard fd >= 0 else { continue }
                    var one: Int32 = 1
                    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                    peers.append(Peer(fd: fd))
                    synchronized { accepted += 1; active += 1 }
                }
            }
        } catch {
            synchronized { failure = error }
        }
    }

    private func receive(from peer: inout Peer) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(peer.fd, &bytes, bytes.count, 0)
        if count == 0 { return false }
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return true }
            if errno == ECONNRESET { return false }
            throw POSIXError(.EIO)
        }
        peer.buffer.append(contentsOf: bytes.prefix(count))
        guard peer.buffer.count <= 65_536 else { throw POSIXError(.EMSGSIZE) }
        while let newline = peer.buffer.firstIndex(of: 10) {
            guard newline > 0, peer.buffer[newline - 1] == 13 else { throw POSIXError(.EPROTO) }
            let data = Data(peer.buffer[..<(newline - 1)])
            peer.buffer.removeSubrange(...newline)
            guard let object = try JSONDecoder().decode(JSONValue.self, from: data).dictionary,
                  object["id"]?.integer != nil, let method = object["method"]?.text,
                  let params = object["params"]?.values else { throw POSIXError(.EPROTO) }
            let shouldHold = synchronized {
                recorded.append(Request(method: method, params: params))
                if held == nil && method == methodsToHold.first {
                    held = (peer.fd, object)
                    methodsToHold.removeFirst()
                    return true
                }
                return false
            }
            if !shouldHold { try respond(to: object, fd: peer.fd) }
        }
        return true
    }

    private func respond(to request: [String: JSONValue], fd: Int32) throws {
        let values: [JSONValue]
        if request["method"]?.text == "get_prop" {
            guard let keys = request["params"]?.values else { throw POSIXError(.EPROTO) }
            // Preserve exactly the requested count/order and return strings, as firmware does.
            values = try keys.map {
                guard case .string(let key) = $0 else { throw POSIXError(.EPROTO) }
                return .string(Self.properties[key] ?? "")
            }
        } else {
            values = [.string("ok")]
        }
        var data = try JSONEncoder().encode(JSONValue.object([
            "id": request["id"]!, "result": .array(values)
        ]))
        data.append(contentsOf: [13, 10])
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw POSIXError(.EIO) }
                offset += sent
            }
        }
    }
}
