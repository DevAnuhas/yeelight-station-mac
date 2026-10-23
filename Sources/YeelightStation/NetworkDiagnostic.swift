import Darwin
import Foundation
import Network
import StationCore

@MainActor
enum NetworkDiagnostic {
    private static var once: Task<Void, Never>?

    static func runIfRequested() async -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--diagnose-network") else { return false }
        // Other windows must await completion too, before their caller terminates the app.
        let task = once ?? Task { await run(arguments) }
        once = task
        await task.value
        return true
    }

    struct Options {
        let host: String
        let output: URL
        init(arguments: [String]) throws {
            func value(_ flag: String) throws -> String? {
                let indices = arguments.indices.filter { arguments[$0] == flag }
                guard indices.count <= 1 else { throw StationError.unavailable("Duplicate \(flag)") }
                guard let index = indices.first else { return nil }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw StationError.unavailable("\(flag) requires a value")
                }
                return arguments[index + 1]
            }
            guard let path = try value("--diagnose-output"), path.hasPrefix("/"),
                  path != "/", !path.hasSuffix("/") else {
                throw StationError.unavailable("--diagnose-network requires --diagnose-output /absolute/path.json")
            }
            host = try value("--diagnose-host") ?? "192.168.8.173"
            var address = in_addr()
            guard inet_pton(AF_INET, host, &address) == 1,
                  (1...223).contains(UInt32(bigEndian: address.s_addr) >> 24) else {
                throw StationError.unavailable("--diagnose-host requires a unicast IPv4 address")
            }
            output = URL(fileURLWithPath: path)
        }
    }

    private static func run(_ arguments: [String]) async {
        let start = ProcessInfo.processInfo.systemUptime
        var report = DiagnosticReport()
        var output: URL?
        // Preserve a usable destination for a failure report even when another option is invalid.
        if let index = arguments.firstIndex(of: "--diagnose-output"), index + 1 < arguments.count,
           arguments[index + 1].hasPrefix("/"), !arguments[index + 1].hasSuffix("/") {
            output = URL(fileURLWithPath: arguments[index + 1])
        }
        do {
            let options = try Options(arguments: arguments)
            output = options.output
            report.host = options.host
            async let route = DiagnosticRouteProbe(host: options.host).run()
            report.scans.append(await scan(host: nil, timeout: 3))
            if report.scans[0].devices.isEmpty { report.scans.append(await scan(host: options.host, timeout: 2)) }
            report.tcp = await route
            report.devices = report.scans.flatMap(\.devices)
            report.errorReason = report.scans.compactMap(\.errorReason).joined(separator: "; ")
            if report.errorReason?.isEmpty == true { report.errorReason = nil }
        } catch { report.errorReason = error.localizedDescription }
        report.finishedAt = Date()
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - start
        do {
            guard let output else { throw StationError.unavailable("No absolute --diagnose-output path; cannot write diagnostic JSON") }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
        } catch { writeError("Diagnostic output failed: \(error.localizedDescription)") }
        print("Network diagnostic: \(report.devices.count) device(s), \(String(format: "%.3f", report.elapsedSeconds))s; output: \(output?.path ?? "missing")")
        if let error = report.errorReason { writeError(error) }
    }

    private static func scan(host: String?, timeout: TimeInterval) async -> DiagnosticScan {
        var result = DiagnosticScan(host: host, timeoutSeconds: timeout)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            result.devices = try await YeelightDiscovery.scan(timeout: timeout, host: host).map(DiagnosticDevice.init)
        } catch { result.errorReason = error.localizedDescription }
        result.finishedAt = Date()
        result.elapsedSeconds = ProcessInfo.processInfo.systemUptime - start
        return result
    }

    private static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(("Network diagnostic: " + text + "\n").utf8))
    }
}

private struct DiagnosticDevice: Encodable, Sendable {
    let id: String, model: String, host: String
    let port: UInt16
    let support: [String]
    init(_ device: LightDevice) {
        id = device.id; model = device.model; host = device.host
        port = device.port; support = device.support.sorted()
    }
}

private struct DiagnosticScan: Encodable, Sendable {
    let host: String?
    let timeoutSeconds: Double
    var startedAt = Date(), finishedAt: Date?
    var elapsedSeconds = 0.0
    var devices: [DiagnosticDevice] = []
    var errorReason: String?
}

private struct DiagnosticReport: Encodable {
    let pid = getpid(), parentPID = getppid()
    let bundleIdentifier = Bundle.main.bundleIdentifier
    let bundlePath = Bundle.main.bundlePath
    let executablePath = Bundle.main.executablePath
    let date = Date(), startedAt = Date()
    let timeoutSeconds = 5.0
    var finishedAt: Date?, host: String?, errorReason: String?
    var elapsedSeconds = 0.0
    var scans: [DiagnosticScan] = []
    var devices: [DiagnosticDevice] = []
    var tcp: DiagnosticRoute?
}

private struct DiagnosticRoute: Encodable, Sendable {
    struct Event: Encodable, Sendable {
        let date: Date, elapsedSeconds: Double, state: String
        let pathStatus: String?, unsatisfiedReason: String?
    }
    let port = 55443, timeoutSeconds = 3.0
    var startedAt = Date(), finishedAt: Date?
    var elapsedSeconds = 0.0
    var outcome = "pending"
    var errorReason: String?
    var events: [Event] = []
}

// Every callback, deadline and completion runs on this private serial queue.
private final class DiagnosticRouteProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "station.network-diagnostic")
    private let connection: NWConnection
    private var result = DiagnosticRoute()
    private var continuation: CheckedContinuation<DiagnosticRoute, Never>?
    private var deadline: DispatchWorkItem?
    private var start = 0.0
    private var cancelled = false
    init(host: String) { connection = NWConnection(host: .init(host), port: 55443, using: .tcp) }

    func run() async -> DiagnosticRoute {
        await withTaskCancellationHandler(operation: { await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.start = ProcessInfo.processInfo.systemUptime
                self.result.startedAt = Date()
                if self.cancelled { self.finish("cancelled"); return }
                self.connection.pathUpdateHandler = { path in self.record("pathUpdate", path) }
                self.connection.stateUpdateHandler = { state in
                    self.record(String(describing: state), self.connection.currentPath)
                    switch state {
                    case .ready: self.finish("ready")
                    case .failed(let error): self.result.errorReason = error.localizedDescription; self.finish("failed")
                    case .waiting(let error): self.result.errorReason = error.localizedDescription
                    case .cancelled: self.finish("cancelled")
                    default: break // Waiting can recover; the independent deadline still bounds it.
                    }
                }
                let deadline = DispatchWorkItem { self.finish("timedOut") }
                self.deadline = deadline
                self.queue.asyncAfter(deadline: .now() + 3, execute: deadline)
                self.connection.start(queue: self.queue) // Handshake only: no send or receive calls.
            }
        } }, onCancel: { self.queue.async { self.cancelled = true; self.finish("cancelled") } })
    }

    private func record(_ state: String, _ path: NWPath?) {
        guard continuation != nil else { return }
        result.events.append(.init(date: Date(), elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                                   state: state, pathStatus: path.map { String(describing: $0.status) },
                                   unsatisfiedReason: path.map { String(describing: $0.unsatisfiedReason) }))
    }

    private func finish(_ outcome: String) {
        guard let continuation else { return }
        record(outcome, connection.currentPath)
        record("cancelRequested", connection.currentPath)
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil
        connection.cancel()
        result.outcome = outcome; result.finishedAt = Date()
        result.elapsedSeconds = ProcessInfo.processInfo.systemUptime - start
        continuation.resume(returning: result)
    }
}
