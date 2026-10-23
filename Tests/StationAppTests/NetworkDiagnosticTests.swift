import XCTest
@testable import YeelightStation

final class NetworkDiagnosticTests: XCTestCase {
    func testDefaultsAndExplicitIPv4() throws {
        let defaults = try NetworkDiagnostic.Options(arguments: ["--diagnose-network", "--diagnose-output", "/tmp/network.json"])
        XCTAssertEqual(defaults.host, "192.168.8.173")
        XCTAssertEqual(defaults.output.path, "/tmp/network.json")
        let explicit = try NetworkDiagnostic.Options(arguments: ["--diagnose-host", "127.0.0.1", "--diagnose-output", "/tmp/network.json"])
        XCTAssertEqual(explicit.host, "127.0.0.1")
    }

    func testRejectsMissingRelativeOrDirectoryDestination() {
        for arguments in [[], ["--diagnose-output"], ["--diagnose-output", "--diagnose-host"],
                          ["--diagnose-output", "network.json"], ["--diagnose-output", "/"],
                          ["--diagnose-output", "/tmp/"]] {
            XCTAssertThrowsError(try NetworkDiagnostic.Options(arguments: arguments))
        }
    }

    func testRejectsMalformedOrNonUnicastHost() {
        for host in ["localhost", "::1", "192.168.8.999", "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.168.8.173:55443"] {
            XCTAssertThrowsError(try NetworkDiagnostic.Options(arguments: ["--diagnose-output", "/tmp/network.json", "--diagnose-host", host]))
        }
    }

    func testRejectsDuplicateOptionsAndMissingHostValue() {
        XCTAssertThrowsError(try NetworkDiagnostic.Options(arguments: ["--diagnose-output", "/tmp/a", "--diagnose-output", "/tmp/b"]))
        XCTAssertThrowsError(try NetworkDiagnostic.Options(arguments: ["--diagnose-output", "/tmp/a", "--diagnose-host"]))
        XCTAssertThrowsError(try NetworkDiagnostic.Options(arguments: ["--diagnose-output", "/tmp/a", "--diagnose-host", "127.0.0.1", "--diagnose-host", "127.0.0.2"]))
    }
}
