import Darwin
import Foundation
import XCTest
@testable import StationCore

final class DiscoveryTests: XCTestCase {
    func testResponseParsesCaseInsensitiveHeadersAndPreservesProperties() throws {
        let packet = response([
            "LoCaTiOn: yeelight://192.168.1.239:55443",
            "ID: 0x000000000015243f",
            "MODEL: lamp15",
            "SUPPORT: get_prop  set_power\tbg_set_rgb udp_sess_new bg_set_rgb",
            "NAME: \(Data("书桌 🌈".utf8).base64EncodedString())",
            "bg_power: on", "strip_length: 12", "Server: POSIX, UPnP/1.0 YGLC/1"
        ])
        let device = try YeelightDiscovery.parse(packet, sourceHost: "192.168.1.239")
        XCTAssertEqual(device.id, "0x000000000015243f")
        XCTAssertEqual(device.model, "lamp15")
        XCTAssertEqual(device.host, "192.168.1.239")
        XCTAssertEqual(device.port, 55443)
        XCTAssertEqual(device.name, "书桌 🌈")
        XCTAssertEqual(device.support, ["get_prop", "set_power", "bg_set_rgb", "udp_sess_new"])
        XCTAssertEqual(device.properties["bg_power"], "on")
        XCTAssertEqual(device.properties["strip_length"], "12")
        XCTAssertEqual(device.properties["server"], "POSIX, UPnP/1.0 YGLC/1")
        XCTAssertEqual(device.properties["name"], Data("书桌 🌈".utf8).base64EncodedString())
    }

    func testAliveNotificationParsesWithoutANameOrResponseOnlyHeaders() throws {
        let packet = response([
            "Location: yeelight://10.0.0.2:12345", "id: 0x2", "model: future_model",
            "support: get_prop", "NTS: ssdp:alive"
        ], start: "NOTIFY * HTTP/1.1 ")
        let device = try YeelightDiscovery.parse(packet)
        XCTAssertEqual(device.host, "10.0.0.2")
        XCTAssertEqual(device.port, 12345)
        XCTAssertEqual(device.name, "")
        XCTAssertEqual(device.model, "future_model")
    }

    func testPlainNamesAndInvalidBase64UTF8FallBackToOriginalName() throws {
        for name in ["Desk light", "书桌", "%%%not-base64%%%", "/w==", "AA=="] {
            XCTAssertEqual(try YeelightDiscovery.parse(validResponse(name: name)).name, name)
        }
        XCTAssertEqual(try YeelightDiscovery.parse(validResponse(name: "TWFu")).name, "Man")
    }

    func testLocationRequiresLiteralUnicastIPv4AndExplicitValidPort() {
        for location in [
            "http://192.168.1.2:55443", "YEELIGHT://192.168.1.2:55443",
            "yeelight://example.com:55443", "yeelight://[::1]:55443",
            "yeelight://2130706433:55443", "yeelight://127.1:55443",
            "yeelight://0x7f000001:55443", "yeelight://127.000.0.1:55443",
            "yeelight://256.1.1.1:55443", "yeelight://0.0.0.0:55443",
            "yeelight://239.255.255.250:55443", "yeelight://255.255.255.255:55443",
            "yeelight://user@127.0.0.1:55443", "yeelight://127.0.0.1:55443/",
            "yeelight://127.0.0.1:55443?x=1", "yeelight://127.0.0.1:55443#x",
            "yeelight://127.0.0.1", "yeelight://127.0.0.1:", "yeelight://127.0.0.1:0",
            "yeelight://127.0.0.1:-1", "yeelight://127.0.0.1:+1",
            "yeelight://127.0.0.1:65536", "yeelight://127.0.0.1:55443:1982"
        ] {
            XCTAssertThrowsError(try YeelightDiscovery.parse(validResponse(location: location)), location)
        }
    }

    func testSourceHostMustMatchLocationWhenSupplied() throws {
        let packet = validResponse(location: "yeelight://127.0.0.1:65535")
        XCTAssertEqual(try YeelightDiscovery.parse(packet, sourceHost: "127.0.0.1").port, 65535)
        for source in ["127.0.0.2", "localhost", "::1", "127.0.0.1\0ignored", "0.0.0.0"] {
            XCTAssertThrowsError(try YeelightDiscovery.parse(packet, sourceHost: source), source)
        }
    }

    func testRejectsMissingIdentityFieldsAndAmbiguousHeaders() {
        let required = ["Location: yeelight://127.0.0.1:55443", "id: 0x1", "model: color", "support: get_prop"]
        for index in required.indices {
            var headers = required
            headers.remove(at: index)
            XCTAssertThrowsError(try YeelightDiscovery.parse(response(headers)))
        }
        for extra in ["LOCATION: yeelight://127.0.0.2:55443", "ID: 0x2", "id: 0x1",
                      " model: color", "model", "bad key: value"] {
            XCTAssertThrowsError(try YeelightDiscovery.parse(response(required + [extra])), extra)
        }
        for extra in ["id: ", "model: "] {
            let key = String(extra.prefix(while: { $0 != ":" }))
            let headers = required.filter { !$0.hasPrefix(key + ":") } + [extra]
            XCTAssertThrowsError(try YeelightDiscovery.parse(response(headers)), extra)
        }
    }

    func testRejectsInvalidStartLinesNotificationsFramingAndEncoding() {
        let headers = ["Location: yeelight://127.0.0.1:55443", "id: 0x1", "model: color", "support: get_prop"]
        for start in ["HTTP/1.1 404 Not Found", "HTTP/1.0 200 OK", " HTTP/1.1 200 OK",
                      "M-SEARCH * HTTP/1.1", "HTTP/1.1 2000 OK"] {
            XCTAssertThrowsError(try YeelightDiscovery.parse(response(headers, start: start)), start)
        }
        XCTAssertThrowsError(try YeelightDiscovery.parse(response(headers, start: "NOTIFY * HTTP/1.1")))
        XCTAssertThrowsError(try YeelightDiscovery.parse(response(headers + ["NTS: ssdp:byebye"], start: "NOTIFY * HTTP/1.1")))
        XCTAssertThrowsError(try YeelightDiscovery.parse(Data("HTTP/1.1 200 OK\n\(headers.joined(separator: "\n"))\n".utf8)))
        XCTAssertThrowsError(try YeelightDiscovery.parse(validResponse() + Data("body".utf8)))
        XCTAssertThrowsError(try YeelightDiscovery.parse(validResponse(name: "hello\0world")))
        XCTAssertThrowsError(try YeelightDiscovery.parse(Data([0xff, 0xfe])))
        XCTAssertThrowsError(try YeelightDiscovery.parse(Data()))
    }

    func testParserBoundsDatagramsLinesHeadersAndNames() {
        XCTAssertThrowsError(try YeelightDiscovery.parse(Data(repeating: 65, count: 16_385)))
        XCTAssertThrowsError(try YeelightDiscovery.parse(validResponse().dropLast(2) + Data("large: \(String(repeating: "a", count: 4096))\r\n\r\n".utf8)))
        let manyHeaders = (0..<129).map { "x-\($0): value" }
        XCTAssertThrowsError(try YeelightDiscovery.parse(response(manyHeaders)))
        XCTAssertThrowsError(try YeelightDiscovery.parse(validResponse(name: String(repeating: "a", count: 257))))
    }

    func testUnicastLoopbackUsesRealUDPValidatesPacketsAndDeduplicates() async throws {
        let requestReceived = expectation(description: "loopback discovery request")
        let simulator = try DiscoveryUDPSimulator()
        simulator.respond(with: [
            .init(data: validResponse(id: "dynamic-port"), alternatePort: true),
            .init(data: validResponse(id: "wrong-location", location: "yeelight://127.0.0.2:55443")),
            .init(data: Data(repeating: 65, count: 17_000)),
            .init(data: Data([0xff])),
            .init(data: validResponse(id: "z")),
            .init(data: validResponse(id: "a")),
            .init(data: validResponse(id: "a", name: "Updated name"))
        ]) { request in
            XCTAssertEqual(String(data: request, encoding: .utf8),
                           "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n")
            requestReceived.fulfill()
        }
        let devices = try await YeelightDiscovery.scan(timeout: 0.2, host: "127.0.0.1", discoveryPort: simulator.port)
        await fulfillment(of: [requestReceived], timeout: 1)
        XCTAssertEqual(devices.map(\.id), ["a", "dynamic-port", "z"])
        XCTAssertEqual(devices.first?.name, "Updated name")
        XCTAssertTrue(devices.allSatisfy { $0.host == "127.0.0.1" })
    }

    func testScanAcceptsDynamicResponseSourcePortAndRespectsDeadline() async throws {
        let simulator = try DiscoveryUDPSimulator()
        simulator.respond(with: [.init(data: validResponse(), alternatePort: true)])
        let start = ContinuousClock.now
        let devices = try await YeelightDiscovery.scan(timeout: 0.1, host: "127.0.0.1", discoveryPort: simulator.port)
        XCTAssertEqual(devices.count, 1)
        let elapsed = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(80))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testCancellationStopsAnInFlightScanPromptly() async throws {
        let requestReceived = expectation(description: "scan started")
        let simulator = try DiscoveryUDPSimulator()
        simulator.respond(with: []) { _ in requestReceived.fulfill() }
        let scan = Task {
            try await YeelightDiscovery.scan(timeout: 30, host: "127.0.0.1", discoveryPort: simulator.port)
        }
        await fulfillment(of: [requestReceived], timeout: 1)
        let start = ContinuousClock.now
        scan.cancel()
        do {
            _ = try await scan.value
            XCTFail("Cancelled discovery must throw")
        } catch is CancellationError {
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testInvalidOptionsAndZeroTimeoutDoNotNeedNetworkDiscovery() async throws {
        let devices = try await YeelightDiscovery.scan(timeout: 0)
        XCTAssertTrue(devices.isEmpty)
        for timeout in [-1.0, .infinity, .nan, 30.1] {
            do {
                _ = try await YeelightDiscovery.scan(timeout: timeout, host: "127.0.0.1")
                XCTFail("Accepted invalid timeout: \(timeout)")
            } catch {}
        }
        for host in ["localhost", "::1", "239.255.255.250", "127.0.0.1:1982", "127.0.0.1\0other"] {
            do {
                _ = try await YeelightDiscovery.scan(timeout: 0, host: host)
                XCTFail("Accepted invalid host: \(host)")
            } catch {}
        }
    }

    private func validResponse(id: String = "0x1", name: String = "Desk light",
                               location: String = "yeelight://127.0.0.1:55443") -> Data {
        response(["Location: \(location)", "id: \(id)", "model: color", "support: get_prop set_rgb", "name: \(name)"])
    }

    private func response(_ headers: [String], start: String = "HTTP/1.1 200 OK") -> Data {
        Data(([start] + headers + ["", ""]).joined(separator: "\r\n").utf8)
    }
}

/// An ephemeral loopback-only UDP peer. Its worker handles one request and is bounded
/// independently of the test, so a failing scan cannot leave a blocked worker behind.
private final class DiscoveryUDPSimulator: @unchecked Sendable {
    struct Reply: Sendable {
        let data: Data
        var alternatePort = false
    }

    let port: UInt16
    private let descriptor: Int32
    private let alternateDescriptor: Int32

    init() throws {
        let primary = try Self.openSocket()
        do {
            let alternate = try Self.openSocket()
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(primary, $0, &length)
                }
            }
            guard result == 0 else {
                Darwin.close(alternate)
                throw Self.posixError()
            }
            descriptor = primary
            alternateDescriptor = alternate
            port = UInt16(bigEndian: address.sin_port)
        } catch {
            Darwin.close(primary)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(alternateDescriptor)
    }

    func respond(with replies: [Reply], onRequest: @escaping @Sendable (Data) -> Void = { _ in }) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pollDescriptor, 1, 1500) > 0 else { return }
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 2048)
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard received > 0 else { return }
            onRequest(Data(buffer.prefix(received)))
            for reply in replies {
                let sent = reply.data.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &source) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(reply.alternatePort ? alternateDescriptor : descriptor,
                                   bytes.baseAddress, bytes.count, 0, $0, length)
                        }
                    }
                }
                XCTAssertEqual(sent, reply.data.count, "Simulator could not send loopback response")
            }
        }
    }

    private static func openSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw posixError() }
        // macOS defaults to a 9 KiB UDP send buffer. This simulator deliberately sends
        // a 17 KiB packet to exercise the discovery parser's 16 KiB datagram limit.
        var sendBuffer: Int32 = 65_536
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &sendBuffer,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let error = posixError()
            Darwin.close(descriptor)
            throw error
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            let error = posixError()
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
