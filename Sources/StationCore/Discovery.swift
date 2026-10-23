import Darwin
import Foundation

public enum YeelightDiscovery {
    /// Searches each active multicast-capable IPv4 interface, or just a literal IPv4 host.
    /// Reply sockets are ephemeral. Reply source ports may differ from 1982 (lamp15 uses 49153). No control
    /// connection is made and no continuous advertisement listener is kept. A scan lasts at most
    /// 30 seconds and returns partial results at its deadline; cancellation throws instead.
    public static func scan(timeout: TimeInterval = 3, host: String? = nil) async throws -> [LightDevice] {
        try await scan(timeout: timeout, host: host, discoveryPort: 1982)
    }

    /// Parses a search response or an ssdp:alive notification. When supplied, sourceHost
    /// must match Location. The protocol does not require a fixed UDP response source port.
    public static func parse(_ data: Data, sourceHost: String? = nil) throws -> LightDevice {
        guard !data.isEmpty, data.count <= Limits.datagramBytes,
              let text = String(data: data, encoding: .utf8),
              text.utf8.allSatisfy({ $0 >= 32 && $0 != 127 || $0 == 9 || $0 == 10 || $0 == 13 }) else {
            throw invalid("Invalid or oversized discovery datagram")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count <= Limits.headers + 3,
              lines.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") && $0.utf8.count <= Limits.lineBytes }),
              let first = lines.first else {
            throw invalid("Invalid discovery header framing")
        }
        // The published NOTIFY example has a trailing space on the start line.
        let start = first.trimmingCharacters(in: .whitespaces)
        guard first.first != " ", first.first != "\t" else {
            throw invalid("Invalid discovery start line")
        }
        let isNotification = start == "NOTIFY * HTTP/1.1"
        guard isNotification || start == "HTTP/1.1 200" || start.hasPrefix("HTTP/1.1 200 ") else {
            throw invalid("Expected a successful discovery response or notification")
        }
        var headers: [String: String] = [:]
        var ended = false
        for line in lines.dropFirst() {
            if line.isEmpty { ended = true; continue }
            guard !ended, line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":") else {
                throw invalid("Malformed discovery header")
            }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isToken(key), headers[key] == nil, headers.count < Limits.headers else {
                throw invalid("Invalid or duplicate discovery header")
            }
            headers[key] = value
        }
        if isNotification && headers["nts"] != "ssdp:alive" {
            throw invalid("Expected an ssdp:alive notification")
        }
        guard let location = headers["location"], location.hasPrefix("yeelight://") else {
            throw invalid("Missing or invalid Yeelight location")
        }
        let endpoint = location.dropFirst("yeelight://".count)
        guard let colon = endpoint.firstIndex(of: ":") else {
            throw invalid("Missing discovery control port")
        }
        let host = String(endpoint[..<colon])
        let portText = endpoint[endpoint.index(after: colon)...]
        guard let address = ipv4(host), !portText.isEmpty, portText.count <= 5,
              portText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = UInt16(portText), port > 0 else {
            throw invalid("Location must contain a unicast IPv4 address and valid control port")
        }
        if let sourceHost {
            guard let source = ipv4(sourceHost), source.s_addr == address.s_addr else {
                throw invalid("Discovery source does not match Location")
            }
        }
        guard let id = headers["id"], id.utf8.count <= 128, isToken(id),
              let model = headers["model"], model.utf8.count <= 64, isToken(model) else {
            throw invalid("Missing or invalid discovery id/model")
        }
        guard let support = headers["support"] else { throw invalid("Missing discovery support list") }
        let methods = support.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard methods.count <= 256, methods.allSatisfy({ $0.utf8.count <= 128 && isToken($0) }) else {
            throw invalid("Invalid discovery support list")
        }
        let rawName = headers["name"] ?? ""
        guard rawName.utf8.count <= 256 else { throw invalid("Oversized discovery name") }
        var name = rawName
        // The protocol permits plain names and recommends Base64 for non-ASCII names.
        // There is no encoding marker: decode only strict Base64 containing printable UTF-8.
        if let decoded = Data(base64Encoded: rawName), let utf8 = String(data: decoded, encoding: .utf8),
           !utf8.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            name = utf8
        }
        return LightDevice(id: id, name: name, model: model, host: host, port: port,
                           support: Set(methods), properties: headers)
    }

    // Internal port injection lets tests exercise the real UDP path on loopback without
    // competing for port 1982 or sending multicast onto the user's network.
    static func scan(timeout: TimeInterval, host: String?, discoveryPort: UInt16) async throws -> [LightDevice] {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout >= 0, timeout <= 30 else {
            throw StationError.unavailable("Discovery timeout must be between 0 and 30 seconds")
        }
        guard discoveryPort != 0 else { throw StationError.invalidAddress }
        let target: in_addr?
        if let host {
            guard let address = ipv4(host) else { throw StationError.invalidAddress }
            target = address
        } else {
            target = nil
        }
        if timeout == 0 { return [] }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            let result: [LightDevice] = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try cancellation.check()
                        let devices = try scanBlocking(target: target, port: discoveryPort,
                                                       deadline: deadline, cancellation: cancellation)
                        try cancellation.check()
                        continuation.resume(returning: devices)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
    }

    private enum Limits {
        static let datagramBytes = 16_384
        static let lineBytes = 4_096
        static let headers = 128
        static let interfaces = 32
        static let devices = 256
        static let datagrams = 4_096
        static let pollMilliseconds: Int32 = 25
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func check() throws {
            lock.lock()
            let value = cancelled
            lock.unlock()
            if value { throw CancellationError() }
        }
    }

    private static func scanBlocking(target: in_addr?, port: UInt16, deadline: ContinuousClock.Instant,
                                     cancellation: Cancellation) throws -> [LightDevice] {
        let locals: [in_addr?]
        if target != nil && port != 1982 { locals = [nil] }
        else { locals = try activeAddresses().map(Optional.some) }
        var sockets: [Int32] = []
        defer { sockets.forEach { Darwin.close($0) } }
        var lastError: Error?
        let request = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n".utf8)
        // The HOST header remains the protocol's fixed multicast endpoint even for a
        // manual unicast probe; its optional value is specified by Yeelight, not HTTP routing.
        var destination = socketAddress(target ?? ipv4Multicast, port: port)
        for local in locals {
            try cancellation.check()
            if ContinuousClock.now >= deadline { break }
            do {
                let socket = try makeSocket(local: local, joinMulticast: port == 1982)
                do {
                    if port == 1982, target != nil {
                        var multicast = socketAddress(ipv4Multicast, port: port)
                        request.withUnsafeBytes { bytes in
                            withUnsafePointer(to: &multicast) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                _ = Darwin.sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            } }
                        }
                    }
                    let sent = request.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &destination) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                Darwin.sendto(socket, bytes.baseAddress, bytes.count, 0, $0,
                                              socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    guard sent == request.count else { throw systemError("send discovery request") }
                    if port == 1982, target == nil {
                        var broadcast = socketAddress(in_addr(s_addr: INADDR_BROADCAST), port: port)
                        request.withUnsafeBytes { bytes in
                            withUnsafePointer(to: &broadcast) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                _ = Darwin.sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            } }
                        }
                    }
                    if ProcessInfo.processInfo.environment["STATION_DISCOVERY_DEBUG"] == "1" {
                        var bound = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socket, $0, &size) } }
                        let detail = "Discovery sent \(sent) bytes to \(hostString(destination.sin_addr) ?? "?"):\(UInt16(bigEndian: destination.sin_port)) from port \(UInt16(bigEndian: bound.sin_port))\n"
                        FileHandle.standardError.write(Data(detail.utf8))
                    }
                    sockets.append(socket)
                } catch {
                    Darwin.close(socket)
                    throw error
                }
            } catch { lastError = error }
        }
        try cancellation.check()
        if sockets.isEmpty {
            if ContinuousClock.now >= deadline { return [] }
            throw lastError ?? StationError.unavailable("No active multicast-capable IPv4 interface")
        }
        var descriptors = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        var devices: [String: LightDevice] = [:]
        var datagrams = 0
        // One extra byte distinguishes a valid maximum-sized datagram from truncation.
        var buffer = [UInt8](repeating: 0, count: Limits.datagramBytes + 1)
        if ProcessInfo.processInfo.environment["STATION_DISCOVERY_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("Discovery begins polling; remaining \(ContinuousClock.now.duration(to: deadline)), sockets \(sockets)\n".utf8))
        }
        while ContinuousClock.now < deadline && datagrams < Limits.datagrams {
            try cancellation.check()
            let now = ContinuousClock.now
            if now >= deadline { break }
            let duration = now.duration(to: deadline).components
            let remainingMS = Int32(min(Int64(Limits.pollMilliseconds),
                                       duration.seconds * 1_000 + (duration.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000))
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), remainingMS)
            if ready < 0 {
                if errno == EINTR { continue }
                throw systemError("poll discovery sockets")
            }
            if ready > 0 && ProcessInfo.processInfo.environment["STATION_DISCOVERY_DEBUG"] == "1" {
                FileHandle.standardError.write(Data("Discovery poll ready \(ready); events \(descriptors.map { $0.revents })\n".utf8))
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                guard descriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                    throw StationError.unavailable("Discovery socket became unavailable")
                }
                guard descriptor.revents & Int16(POLLIN) != 0 else { continue }
                // Bound each drain as well as the entire scan, so a packet flood cannot
                // starve other interfaces, cancellation, or the monotonic deadline.
                for _ in 0..<32 {
                    try cancellation.check()
                    if ContinuousClock.now >= deadline || datagrams >= Limits.datagrams { break }
                    var source = sockaddr_in()
                    var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let received = buffer.withUnsafeMutableBytes { bytes in
                        withUnsafeMutablePointer(to: &source) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                Darwin.recvfrom(descriptor.fd, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
                            }
                        }
                    }
                    if received < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        if errno == EINTR { continue }
                        throw systemError("receive discovery response")
                    }
                    datagrams += 1
                    if ProcessInfo.processInfo.environment["STATION_DISCOVERY_DEBUG"] == "1" {
                        let detail = "Discovery reply from \(hostString(source.sin_addr) ?? "?"):\(UInt16(bigEndian: source.sin_port)), \(received) bytes, address size \(sourceLength)\n"
                        FileHandle.standardError.write(Data(detail.utf8))
                    }
                    guard received > 0, received <= Limits.datagramBytes,
                          sourceLength >= MemoryLayout<sockaddr_in>.size,
                          source.sin_family == sa_family_t(AF_INET), source.sin_port != 0,
                          target == nil || target?.s_addr == source.sin_addr.s_addr,
                          let sourceHost = hostString(source.sin_addr),
                          let device = try? parse(Data(buffer.prefix(received)), sourceHost: sourceHost) else { continue }
                    devices[device.id] = device
                    if devices.count >= Limits.devices { return sorted(devices) }
                }
            }
        }
        return sorted(devices)
    }

    private static func makeSocket(local: in_addr?, joinMulticast: Bool) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw systemError("open discovery socket") }
        do {
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw systemError("configure discovery socket")
            }
            var address = socketAddress(local ?? in_addr(s_addr: 0), port: 0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw systemError("bind discovery socket") }
            if joinMulticast {
                var broadcast: Int32 = 1
                guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw systemError("enable discovery broadcast fallback")
                }
                // IGMP membership is required on some Wi-Fi/router combinations even
                // though search responses arrive unicast on this ephemeral port.
                var membership = ip_mreq(imr_multiaddr: ipv4Multicast, imr_interface: local ?? in_addr(s_addr: 0))
                guard setsockopt(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership,
                                 socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                    throw systemError("join Yeelight discovery group")
                }
            }
            if var local {
                guard setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, &local,
                                 socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
                    throw systemError("select discovery multicast interface")
                }
                var ttl: UInt8 = 1
                var loop: UInt8 = 0
                guard setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1) == 0,
                      setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, 1) == 0 else {
                    throw systemError("configure discovery multicast")
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func activeAddresses() throws -> [in_addr] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw systemError("enumerate IPv4 interfaces") }
        defer { if let first { freeifaddrs(first) } }
        var addresses: [UInt32: in_addr] = [:]
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let interface = entry.pointee
            let required = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
            guard interface.ifa_flags & required == required,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let leadingOctet = UInt32(bigEndian: value.s_addr) >> 24
            guard leadingOctet > 0, leadingOctet < 224 else { continue }
            addresses[value.s_addr] = value
        }
        return addresses.values.sorted { UInt32(bigEndian: $0.s_addr) < UInt32(bigEndian: $1.s_addr) }
            .prefix(Limits.interfaces).map { $0 }
    }

    private static var ipv4Multicast: in_addr { in_addr(s_addr: UInt32(0xEFFF_FFFA).bigEndian) }

    private static func ipv4(_ host: String) -> in_addr? {
        // Darwin inet_pton accepts leading-zero octets. Validate the original text first
        // so platform-dependent normalization cannot admit alternate numeric spellings.
        guard host.utf8.count <= 15 else { return nil }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 3 && ($0.count == 1 || $0.first != "0")
                && $0.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) && UInt8($0) != nil
        }) else { return nil }
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        let leadingOctet = UInt32(bigEndian: address.s_addr) >> 24
        guard leadingOctet > 0, leadingOctet < 224 else { return nil }
        return address
    }

    private static func hostString(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func socketAddress(_ address: in_addr, port: UInt16) -> sockaddr_in {
        var result = sockaddr_in()
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        result.sin_family = sa_family_t(AF_INET)
        result.sin_addr = address
        result.sin_port = port.bigEndian
        return result
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    private static func sorted(_ devices: [String: LightDevice]) -> [LightDevice] {
        devices.values.sorted { $0.id < $1.id }
    }

    private static func invalid(_ message: String) -> StationError { .invalidResponse(message) }

    private static func systemError(_ operation: String) -> StationError {
        let code = errno
        return .unavailable("Could not \(operation): \(String(cString: strerror(code))) (\(code))")
    }
}
