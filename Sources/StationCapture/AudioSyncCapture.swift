import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
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
    private let inputCatalog: AudioInputDeviceCatalog
    private let microphonePermission: @MainActor () async throws -> Void
    private let makeMicrophoneEngine: @MainActor () -> any MicrophoneInputEngine

    public init() {
        inputCatalog = AudioInputDeviceCatalog()
        microphonePermission = Self.requireMicrophonePermission
        makeMicrophoneEngine = { AVMicrophoneInputEngine() }
    }

    init(inputHardware: any AudioInputHardware,
         microphonePermission: @escaping @MainActor () async throws -> Void,
         makeMicrophoneEngine: @escaping @MainActor () -> any MicrophoneInputEngine) {
        inputCatalog = AudioInputDeviceCatalog(hardware: inputHardware)
        self.microphonePermission = microphonePermission
        self.makeMicrophoneEngine = makeMicrophoneEngine
    }

    /// CoreAudio metadata only; does not create an engine or request capture access.
    public func availableAudioInputs() throws -> [AudioInputDevice] {
        try inputCatalog.availableInputs()
    }

    public func start(source: AudioSource, displayID: UInt32? = nil,
                      inputDeviceUID: String? = nil,
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
                let display: SCDisplay
                if let displayID {
                    guard let selected = content.displays.first(where: { $0.displayID == displayID }) else {
                        throw CaptureError.displayUnavailable(displayID)
                    }
                    display = selected
                } else {
                    guard let fallback = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else { throw CaptureError.noDisplays }
                    display = fallback
                }
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
                // Freeze the default to a UID before authorization can suspend.
                // A missing pinned input must fail before any permission request.
                let uid = try inputCatalog.resolve(uid: inputDeviceUID).device.id
                try await microphonePermission()
                try ensureCurrent(token)
                // Resolve again after permission, before creating/opening the engine.
                let deviceID = try inputCatalog.resolve(uid: uid).deviceID
                newSession = MicrophoneCaptureSession(deviceID: deviceID, engine: makeMicrophoneEngine(), delivery: delivery)
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
final class MicrophoneCaptureSession: CaptureSession {
    private let deviceID: AudioDeviceID
    private let engine: any MicrophoneInputEngine
    private let delivery: CaptureDelivery<Double>
    private let mailbox: CaptureMailbox<Double>
    private var stopped = false

    init(deviceID: AudioDeviceID, engine: any MicrophoneInputEngine, delivery: CaptureDelivery<Double>) {
        self.deviceID = deviceID
        self.engine = engine
        self.delivery = delivery
        mailbox = delivery.mailbox
    }

    func start() async throws {
        // Set the underlying AUHAL before reading its new format, installing a tap,
        // preparing, or starting. Never change initialization on engine-owned units.
        try engine.selectDevice(deviceID)
        let format = engine.outputFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 32 else { throw CaptureError.microphoneUnavailable }
        guard format.commonFormat == .pcmFormatFloat32 else { throw CaptureError.unsupportedAudioFormat }
        let mailbox = mailbox
        engine.installTap(format: format, onBuffer: { buffer in
            do {
                if let rms = try AudioLevelMeter.rms(in: buffer) { mailbox.publish(rms) }
            } catch {
                mailbox.fail((error as? CaptureError) ?? .invalidAudioBuffer)
            }
        }, onConfigurationChange: {
            // The notification arrives on an internal audio queue. Defer
            // teardown to the main delivery timer to avoid engine deadlock.
            mailbox.fail(.microphoneConfigurationChanged)
        })
        do {
            try engine.prepareAndStart()
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
        engine.stop()
    }

    deinit {
        mailbox.invalidate()
        if !stopped { engine.stop() }
    }
}

/// The session drives this adapter on main. Its final ARC cleanup may run on any
/// thread, so cleanup uses no actor precondition. Tests substitute a silent engine.
protocol MicrophoneInputEngine: AnyObject {
    func selectDevice(_ id: AudioDeviceID) throws
    var outputFormat: AVAudioFormat { get }
    func installTap(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onConfigurationChange: @escaping @Sendable () -> Void)
    func prepareAndStart() throws
    func stop()
}

private final class AVMicrophoneInputEngine: MicrophoneInputEngine {
    private let engine = AVAudioEngine()
    private var installedTap = false
    private var observer: NSObjectProtocol?
    private var selectedDeviceID: AudioDeviceID?

    func selectDevice(_ id: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else { throw CaptureError.microphoneUnavailable }
        try AudioUnitInputDeviceSelection(audioUnit: unit).select(id)
        selectedDeviceID = id
    }

    var outputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func installTap(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onConfigurationChange: @escaping @Sendable () -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in onBuffer(buffer) }
        installedTap = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in onConfigurationChange() }
    }

    func prepareAndStart() throws {
        engine.prepare()
        try engine.start()
        // A route change during startup must not silently capture a fallback input.
        guard let id = selectedDeviceID, let unit = engine.inputNode.audioUnit else {
            throw CaptureError.microphoneUnavailable
        }
        try AudioUnitInputDeviceSelection(audioUnit: unit).verify(id)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0) }
        installedTap = false
    }

    deinit { stop() }
}
