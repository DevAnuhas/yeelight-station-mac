import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit

public enum AudioSource: String, CaseIterable, Identifiable, Sendable {
    case system
    case microphone

    public var id: String { rawValue }
}

@MainActor
public final class AudioSyncCapture: ObservableObject {
    @Published public private(set) var isRunning = false
    /// Includes stream termination, input changes, and invalid runtime formats.
    @Published public private(set) var lastError: String?

    private var generation = UUID()
    private var session: (any CaptureSession)?
    private var teardownTask: Task<Void, Never>?

    public init() {}

    public func start(source: AudioSource,
                      onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let token = UUID()
        generation = token
        lastError = nil
        let teardown = retireSession()
        await teardown?.value
        do {
            try ensureCurrent(token)
            let mailbox = CaptureMailbox<Double>()
            let smoother = AudioLevelSmoother()
            let delivery = CaptureDelivery(mailbox: mailbox, interval: 0.05, staleValue: 0,
                onValue: { [weak self] rms in
                    guard let self, self.generation == token, self.isRunning else { return }
                    onLevel(smoother.consume(rms: rms))
                }, onFailure: { [weak self] error in self?.handleFailure(error, token: token) })
            let newSession: any CaptureSession
            switch source {
            case .system:
                try CapturePermission.requireScreenRecording()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try ensureCurrent(token)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else { throw CaptureError.noDisplays }
                let configuration = SCStreamConfiguration()
                // Only audio is consumed; keep the associated display surface tiny.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                let output = AudioStreamOutput(mailbox: mailbox)
                newSession = try StreamCaptureSession(
                    filter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: configuration, output: output, outputTypes: [.audio],
                    queue: DispatchQueue(label: "station.capture.audio", qos: .userInitiated), delivery: delivery)
            case .microphone:
                try await Self.requireMicrophonePermission()
                try ensureCurrent(token)
                newSession = MicrophoneCaptureSession(delivery: delivery)
            }
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

    private static func requireMicrophonePermission() async throws {
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // macOS can terminate a process that requests access without this key.
            throw CaptureError.missingMicrophoneUsageDescription
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CaptureError.microphonePermissionDenied
            }
        case .denied, .restricted: throw CaptureError.microphonePermissionDenied
        @unknown default: throw CaptureError.microphonePermissionDenied
        }
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

private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let mailbox: CaptureMailbox<Double>

    init(mailbox: CaptureMailbox<Double>) { self.mailbox = mailbox }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        do {
            if let rms = try AudioLevelMeter.rms(in: sampleBuffer) { mailbox.publish(rms) }
        } catch {
            mailbox.fail((error as? CaptureError) ?? .invalidAudioBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        mailbox.fail(.streamStopped(error.localizedDescription))
    }
}

@MainActor
private final class MicrophoneCaptureSession: CaptureSession {
    private let engine = AVAudioEngine()
    private let delivery: CaptureDelivery<Double>
    private let mailbox: CaptureMailbox<Double>
    private var installedTap = false
    private var stopped = false
    private var observer: NSObjectProtocol?

    init(delivery: CaptureDelivery<Double>) {
        self.delivery = delivery
        mailbox = delivery.mailbox
    }

    func start() async throws {
        guard AVCaptureDevice.default(for: .audio) != nil else { throw CaptureError.microphoneUnavailable }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 32 else { throw CaptureError.microphoneUnavailable }
        guard format.commonFormat == .pcmFormatFloat32 else { throw CaptureError.unsupportedAudioFormat }
        let mailbox = mailbox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do {
                if let rms = try AudioLevelMeter.rms(in: buffer) { mailbox.publish(rms) }
            } catch {
                mailbox.fail((error as? CaptureError) ?? .invalidAudioBuffer)
            }
        }
        installedTap = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                // The notification arrives on an internal audio queue. Defer
                // teardown to the main delivery timer to avoid engine deadlock.
                mailbox.fail(.microphoneConfigurationChanged)
            }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw CaptureError.startFailed(error.localizedDescription)
        }
        if let error = mailbox.terminalError { throw error }
    }

    func beginDelivery() { delivery.start() }

    func invalidate() { delivery.invalidate() }

    func stop() async {
        invalidate()
        guard !stopped else { return }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0) }
        installedTap = false
    }

    deinit {
        mailbox.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0) }
    }
}
