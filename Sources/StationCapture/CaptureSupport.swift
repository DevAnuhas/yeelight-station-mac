import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureError: Error, LocalizedError, Sendable, Equatable {
    case screenRecordingPermissionRequired
    case microphonePermissionDenied
    case missingMicrophoneUsageDescription
    case microphoneUnavailable
    case microphoneConfigurationChanged
    case noDisplays
    case displayUnavailable(UInt32)
    case displayEnumerationFailed
    case invalidInterval
    case unsupportedPixelFormat
    case unsupportedAudioFormat
    case invalidAudioBuffer
    case streamStopped(String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            return "Allow Screen Recording for this app in System Settings → Privacy & Security, then reopen the app if macOS asks."
        case .microphonePermissionDenied:
            return "Allow Microphone access for this app in System Settings → Privacy & Security."
        case .missingMicrophoneUsageDescription:
            return "Microphone capture requires NSMicrophoneUsageDescription in the app's Info.plist."
        case .microphoneUnavailable:
            return "No usable microphone input is available. Connect or select an input device and start again."
        case .microphoneConfigurationChanged:
            return "The audio input configuration changed. Start microphone capture again."
        case .noDisplays: return "No display is available for capture."
        case .displayUnavailable(let id): return "Display \(id) is no longer available. Select a display and start again."
        case .displayEnumerationFailed: return "macOS could not enumerate the connected displays."
        case .invalidInterval: return "The screen sampling interval must be a finite number greater than zero."
        case .unsupportedPixelFormat: return "Screen capture did not provide a readable BGRA pixel buffer."
        case .unsupportedAudioFormat: return "Audio capture requires native float32 PCM audio."
        case .invalidAudioBuffer: return "Audio capture returned an invalid or incomplete audio buffer."
        case .streamStopped(let message): return "Capture stopped: \(message)"
        case .startFailed(let message): return "Capture could not start: \(message)"
        }
    }
}

/// A single-slot mailbox. Capture queues never enqueue work on the main actor.
/// A terminal error takes priority over samples and prevents further publication.
final class CaptureMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var value: Value?
    private var failure: CaptureError?

    func publish(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard active, failure == nil else { return }
        value = newValue
    }

    func fail(_ error: CaptureError) {
        lock.lock()
        defer { lock.unlock() }
        guard active, failure == nil else { return }
        failure = error
        value = nil
    }

    func take() -> Result<Value, CaptureError>? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        if let failure { return .failure(failure) }
        guard let value else { return nil }
        self.value = nil
        return .success(value)
    }

    var terminalError: CaptureError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        value = nil
    }
}

/// The timer and all client callbacks run on the main actor. Canceling it and
/// invalidating its mailbox synchronously closes delivery before async teardown.
@MainActor
final class CaptureDelivery<Value: Sendable> {
    let mailbox: CaptureMailbox<Value>
    private let interval: TimeInterval
    private let staleValue: Value?
    private let onValue: @MainActor @Sendable (Value) -> Void
    private let onFailure: @MainActor @Sendable (CaptureError) -> Void
    private var timer: DispatchSourceTimer?
    private var active = true
    private var lastSampleTime = ProcessInfo.processInfo.systemUptime

    init(mailbox: CaptureMailbox<Value>, interval: TimeInterval, staleValue: Value? = nil,
         onValue: @escaping @MainActor @Sendable (Value) -> Void,
         onFailure: @escaping @MainActor @Sendable (CaptureError) -> Void) {
        self.mailbox = mailbox
        self.interval = interval
        self.staleValue = staleValue
        self.onValue = onValue
        self.onFailure = onFailure
    }

    func start() {
        guard active, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        guard active else { return }
        // Rearm after delivery instead of letting a delayed repeating timer
        // catch up with closely spaced callbacks on a busy main thread.
        defer {
            if active { timer?.schedule(deadline: .now() + interval, leeway: .milliseconds(2)) }
        }
        switch mailbox.take() {
        case .success(let value):
            lastSampleTime = ProcessInfo.processInfo.systemUptime
            onValue(value)
        case .failure(let error):
            invalidate()
            onFailure(error)
        case nil:
            // Some sources stop delivering buffers during silence. Decay their
            // level rather than leaving the last loud frame stuck indefinitely.
            if let staleValue, ProcessInfo.processInfo.systemUptime - lastSampleTime >= 0.15 {
                onValue(staleValue)
            }
        }
    }

    func invalidate() {
        active = false
        mailbox.invalidate()
        timer?.cancel()
        timer = nil
    }

    deinit {
        mailbox.invalidate()
        timer?.cancel()
    }
}

@MainActor
protocol CaptureSession: AnyObject {
    func start() async throws
    func beginDelivery()
    func invalidate()
    func stop() async
}

/// Remembers the in-flight start so Stop also covers a stream whose start
/// completion has not arrived yet. Multiple teardown paths share one stop task.
@MainActor
final class StreamCaptureSession<Value: Sendable>: CaptureSession {
    private let stream: SCStream
    private let output: any SCStreamOutput & SCStreamDelegate
    private let outputTypes: [SCStreamOutputType]
    private let delivery: CaptureDelivery<Value>
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration,
         output: any SCStreamOutput & SCStreamDelegate,
         outputTypes: [SCStreamOutputType], queue: DispatchQueue,
         delivery: CaptureDelivery<Value>) throws {
        self.output = output
        self.outputTypes = outputTypes
        self.delivery = delivery
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        for type in outputTypes {
            try stream.addStreamOutput(output, type: type, sampleHandlerQueue: queue)
        }
    }

    func start() async throws {
        let stream = stream
        let task = Task { try await stream.startCapture() }
        startTask = task
        try await task.value
        if let error = delivery.mailbox.terminalError { throw error }
    }

    func beginDelivery() { delivery.start() }

    func invalidate() { delivery.invalidate() }

    func stop() async {
        invalidate()
        if let stopTask {
            await stopTask.value
            return
        }
        let stream = stream
        let output = output
        let types = outputTypes
        let startTask = startTask
        let task = Task {
            _ = try? await startTask?.value
            try? await stream.stopCapture()
            for type in types { try? stream.removeStreamOutput(output, type: type) }
        }
        stopTask = task
        await task.value
    }

    deinit {
        delivery.mailbox.invalidate()
        if stopTask == nil {
            let stream = stream
            let output = output
            let startTask = startTask
            Task {
                _ = try? await startTask?.value
                try? await stream.stopCapture()
                _ = output // Retain the delegate through stream shutdown.
            }
        }
    }
}

@MainActor
enum CapturePermission {
    static func requireScreenRecording() throws {
        // Only called by Start; display enumeration deliberately avoids SCK.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.screenRecordingPermissionRequired
        }
    }
}

@MainActor
final class AudioLevelSmoother {
    private var level = 0.0
    private var previousTime: TimeInterval?

    func consume(rms: Double, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        let safeRMS = rms.isFinite ? min(1, max(0, rms)) : 0
        // Map -60...-6 dBFS onto 0...1 for useful response to normal music.
        let target = safeRMS > 0 ? min(1, max(0, (20 * log10(safeRMS) + 60) / 54)) : 0
        let elapsed = min(1, max(0, now - (previousTime ?? (now - 0.05))))
        previousTime = now
        let timeConstant = target > level ? 0.035 : 0.20
        level += (target - level) * (1 - exp(-elapsed / timeConstant))
        if level < 0.0001 { level = 0 }
        return min(1, max(0, level))
    }
}
