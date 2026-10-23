import AppKit
import Combine
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import StationCore

public struct CaptureDisplay: Identifiable, Sendable, Hashable {
    public let id: UInt32
    public let name: String
    /// Display dimensions in physical pixels.
    public let width: Int
    public let height: Int

    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}

@MainActor
public final class ScreenSyncCapture: ObservableObject {
    @Published public private(set) var isRunning = false
    /// Includes failures reported asynchronously after a successful Start.
    @Published public private(set) var lastError: String?

    private var generation = UUID()
    private var session: StreamCaptureSession<[StationCore.RGBColor]>?
    private var teardownTask: Task<Void, Never>?

    public init() {}

    /// Enumerating Core Graphics display IDs does not request recording access.
    public func availableDisplays() async throws -> [CaptureDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw CaptureError.displayEnumerationFailed
        }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let result = ids.withUnsafeMutableBufferPointer {
            CGGetActiveDisplayList(count, $0.baseAddress, &count)
        }
        guard result == .success else { throw CaptureError.displayEnumerationFailed }
        return ids.prefix(Int(count)).map { id in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            return CaptureDisplay(id: id, name: screen?.localizedName ?? "Display \(id)",
                                  width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        }
    }

    public func start(displayID: UInt32, zones: [SampleRect], interval: TimeInterval,
                      onColors: @escaping @MainActor @Sendable ([StationCore.RGBColor]) -> Void) async throws {
        let token = UUID()
        generation = token
        lastError = nil
        let teardown = retireSession()
        await teardown?.value
        do {
            try ensureCurrent(token)
            guard interval.isFinite, interval > 0 else { throw CaptureError.invalidInterval }
            try CapturePermission.requireScreenRecording()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try ensureCurrent(token)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayUnavailable(displayID)
            }

            let period = min(60, max(0.1, interval))
            let configuration = SCStreamConfiguration()
            let scale = min(1, 320.0 / Double(max(1, max(display.width, display.height))))
            configuration.width = max(2, Int((Double(display.width) * scale).rounded()))
            configuration.height = max(2, Int((Double(display.height) * scale).rounded()))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = false
            configuration.queueDepth = 3
            configuration.minimumFrameInterval = CMTime(seconds: period, preferredTimescale: 60_000)
            configuration.capturesAudio = false

            let mailbox = CaptureMailbox<[StationCore.RGBColor]>()
            let delivery = CaptureDelivery(mailbox: mailbox, interval: period,
                onValue: { [weak self] colors in
                    guard let self, self.generation == token, self.isRunning else { return }
                    onColors(colors)
                }, onFailure: { [weak self] error in self?.handleFailure(error, token: token) })
            let output = ScreenStreamOutput(zones: zones, mailbox: mailbox)
            let newSession = try StreamCaptureSession(
                filter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration, output: output, outputTypes: [.screen],
                queue: DispatchQueue(label: "station.capture.screen", qos: .userInitiated), delivery: delivery)
            session = newSession
            try await newSession.start()
            try ensureCurrent(token)
            isRunning = true
            newSession.beginDelivery()
        } catch {
            if generation == token {
                if !(error is CancellationError) { lastError = error.localizedDescription }
                let teardown = retireSession()
                await teardown?.value
            }
            throw error
        }
    }

    public func stop() async {
        generation = UUID()
        let teardown = retireSession()
        await teardown?.value
    }

    private func ensureCurrent(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func handleFailure(_ error: CaptureError, token: UUID) {
        guard generation == token else { return }
        lastError = error.localizedDescription
        generation = UUID()
        _ = retireSession()
    }

    @discardableResult
    private func retireSession() -> Task<Void, Never>? {
        let oldSession = session
        oldSession?.invalidate()
        session = nil
        isRunning = false
        guard let oldSession else { return teardownTask }
        let previous = teardownTask
        let task = Task {
            await previous?.value
            await oldSession.stop()
        }
        teardownTask = task
        return task
    }
}

private final class ScreenStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let zones: [SampleRect]
    private let mailbox: CaptureMailbox<[StationCore.RGBColor]>

    init(zones: [SampleRect], mailbox: CaptureMailbox<[StationCore.RGBColor]>) {
        self.zones = zones
        self.mailbox = mailbox
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        if status == .blank || status == .suspended {
            mailbox.publish(zones.map { _ in .black })
            return
        }
        guard status == .complete, let pixels = sampleBuffer.imageBuffer else { return }
        guard let colors = ScreenColorSampler.colors(in: pixels, zones: zones) else {
            mailbox.fail(.unsupportedPixelFormat)
            return
        }
        mailbox.publish(colors)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        mailbox.fail(.streamStopped(error.localizedDescription))
    }
}
