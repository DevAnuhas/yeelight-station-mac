import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import XCTest
@testable import StationCapture

private final class InputHardware: AudioInputHardware {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let channels: UInt32
        var name = "Input"
    }
    var devices: [Device] = [Device(id: 10, uid: "built-in", channels: 1), Device(id: 20, uid: "usb", channels: 2)]
    var defaultID: AudioDeviceID = 10
    var unreadable = Set<AudioDeviceID>()

    func deviceIDs() throws -> [AudioDeviceID] { devices.map(\.id) }
    func defaultInputID() throws -> AudioDeviceID { defaultID }
    func inputChannelCount(_ id: AudioDeviceID) throws -> UInt32 {
        guard !unreadable.contains(id) else { throw AudioInputError.hardwareReadFailed(-1) }
        return devices.first { $0.id == id }!.channels
    }
    func uid(_ id: AudioDeviceID) throws -> String { devices.first { $0.id == id }!.uid }
    func name(_ id: AudioDeviceID) throws -> String { devices.first { $0.id == id }!.name }
}

final class AudioInputDeviceTests: XCTestCase {
    func testInventoryFiltersOutputOnlyDevicesAndMarksTheActualDefault() throws {
        let hardware = InputHardware()
        hardware.devices.append(.init(id: 30, uid: "speakers", channels: 0))
        hardware.devices.append(.init(id: 40, uid: "interface", channels: 8))
        hardware.defaultID = 20
        let inputs = try AudioInputDeviceCatalog(hardware: hardware).availableInputs()
        XCTAssertEqual(inputs.map(\.id), ["usb", "built-in", "interface"])
        XCTAssertEqual(inputs.map(\.isDefault), [true, false, false])
        XCTAssertEqual(inputs.map(\.name), ["Input", "Input", "Input"])
    }

    func testPinnedUIDNeverFallsBackAndDefaultRequiresAnInput() throws {
        let hardware = InputHardware()
        let catalog = AudioInputDeviceCatalog(hardware: hardware)
        XCTAssertThrowsError(try catalog.resolve(uid: "gone")) {
            XCTAssertEqual($0 as? AudioInputError, .unavailable("gone"))
        }
        hardware.defaultID = kAudioObjectUnknown
        XCTAssertThrowsError(try catalog.resolve(uid: nil)) {
            XCTAssertEqual($0 as? AudioInputError, .unavailable(nil))
        }
        XCTAssertEqual(try catalog.resolve(uid: "usb").deviceID, 20)
    }

    func testResolutionReReadsUIDsCapabilitiesAndTransientDeviceIDs() throws {
        let hardware = InputHardware()
        let catalog = AudioInputDeviceCatalog(hardware: hardware)
        XCTAssertEqual(try catalog.resolve(uid: "usb").deviceID, 20)
        hardware.devices = [.init(id: 50, uid: "usb", channels: 2)]
        hardware.defaultID = 50
        XCTAssertEqual(try catalog.resolve(uid: "usb").deviceID, 50)
        hardware.devices = [.init(id: 50, uid: "usb", channels: 0)]
        XCTAssertThrowsError(try catalog.resolve(uid: "usb"))
    }

    func testHotUnplugDuringEnumerationDoesNotHideOtherInputs() throws {
        let hardware = InputHardware()
        hardware.unreadable.insert(10)
        XCTAssertEqual(try AudioInputDeviceCatalog(hardware: hardware).availableInputs().map(\.id), ["usb"])
    }

    func testInputChannelListIncludesEveryBufferAndRejectsTruncatedStorage() throws {
        let list = AudioBufferList.allocate(maximumBuffers: 3)
        defer { list.unsafeMutablePointer.deallocate() }
        list[0] = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)
        list[2] = AudioBuffer(mNumberChannels: 4, mDataByteSize: 0, mData: nil)
        let bytes = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! + 3 * MemoryLayout<AudioBuffer>.stride
        XCTAssertEqual(try audioInputChannelCount(in: list.unsafePointer, byteCount: bytes), 6)
        XCTAssertThrowsError(try audioInputChannelCount(in: list.unsafePointer, byteCount: bytes - 1))
        XCTAssertThrowsError(try audioInputChannelCount(in: list.unsafePointer, byteCount: 0))
        list[1].mNumberChannels = .max
        XCTAssertThrowsError(try audioInputChannelCount(in: list.unsafePointer, byteCount: bytes))
    }

    func testAudioUnitSelectionWritesCurrentDeviceAtGlobalElementZeroAndReadsItBack() throws {
        var operations: [String] = []
        var selected: AudioDeviceID = 0
        let selection = AudioUnitInputDeviceSelection(set: { property, scope, element, id in
            XCTAssertEqual(property, kAudioOutputUnitProperty_CurrentDevice)
            XCTAssertEqual(scope, kAudioUnitScope_Global)
            XCTAssertEqual(element, 0)
            operations.append("set")
            selected = id
            return noErr
        }, get: { property, scope, element, id in
            XCTAssertEqual(property, kAudioOutputUnitProperty_CurrentDevice)
            XCTAssertEqual(scope, kAudioUnitScope_Global)
            XCTAssertEqual(element, 0)
            operations.append("get")
            id = selected
            return noErr
        })
        try selection.select(987)
        XCTAssertEqual(selected, 987)
        XCTAssertEqual(operations, ["set", "get"])
    }

    func testAudioUnitRejectsSetErrorsReadErrorsAndUnexpectedFallback() {
        var readCount = 0
        let failedSet = AudioUnitInputDeviceSelection(set: { _, _, _, _ in -11 }, get: { _, _, _, _ in
            readCount += 1
            return noErr
        })
        XCTAssertThrowsError(try failedSet.select(20)) { XCTAssertEqual($0 as? AudioInputError, .selectionFailed(-11)) }
        XCTAssertEqual(readCount, 0)
        let failedRead = AudioUnitInputDeviceSelection(set: { _, _, _, _ in noErr }, get: { _, _, _, _ in -12 })
        XCTAssertThrowsError(try failedRead.select(20)) { XCTAssertEqual($0 as? AudioInputError, .selectionFailed(-12)) }
        let fallback = AudioUnitInputDeviceSelection(set: { _, _, _, _ in noErr }, get: { _, _, _, id in
            id = 10
            return noErr
        })
        XCTAssertThrowsError(try fallback.select(20)) { XCTAssertEqual($0 as? AudioInputError, .selectionDidNotMatch) }
    }

    func testRouteVerificationNeverWritesToARunningAudioUnit() throws {
        var actual: AudioDeviceID = 20
        let selection = AudioUnitInputDeviceSelection(set: { _, _, _, _ in
            XCTFail("Runtime verification must not set initialized unit properties")
            return noErr
        }, get: { _, _, _, id in
            id = actual
            return noErr
        })
        try selection.verify(20)
        actual = 10
        XCTAssertThrowsError(try selection.verify(20)) { XCTAssertEqual($0 as? AudioInputError, .selectionDidNotMatch) }
    }
}

private final class InputEngine: MicrophoneInputEngine {
    var operations: [String] = []
    var selectedID: AudioDeviceID?
    var selectionError: Error?
    var startError: Error?
    var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    var configurationChanged: (@Sendable () -> Void)?
    var outputFormat: AVAudioFormat {
        operations.append("format")
        return format
    }
    func selectDevice(_ id: AudioDeviceID) throws {
        operations.append("select")
        if let selectionError { throw selectionError }
        selectedID = id
    }
    func installTap(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onConfigurationChange: @escaping @Sendable () -> Void) {
        operations.append("tap")
        configurationChanged = onConfigurationChange
    }
    func prepareAndStart() throws {
        operations.append("start")
        if let startError { throw startError }
    }
    func stop() {
        operations.append("stop")
        configurationChanged = nil
    }
}

@MainActor
final class AudioInputCaptureTests: XCTestCase {
    func testInventoryAndStaleStartDoNotRequestPermissionOrCreateAnEngine() async throws {
        var permissions = 0
        var engines = 0
        let capture = AudioSyncCapture(inputHardware: InputHardware(), microphonePermission: { permissions += 1 }, makeMicrophoneEngine: {
            engines += 1
            return InputEngine()
        })
        XCTAssertEqual(try capture.availableAudioInputs().count, 2)
        do {
            try await capture.start(source: .microphone, inputDeviceUID: "gone") { _ in XCTFail("Unexpected level") }
            XCTFail("Stale input must fail")
        } catch { XCTAssertEqual(error as? AudioInputError, .unavailable("gone")) }
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(engines, 0)
        XCTAssertFalse(capture.isRunning)
    }

    func testPinnedUIDReResolvesAfterPermissionAndIsSetBeforeTapOrStart() async throws {
        let hardware = InputHardware()
        let engine = InputEngine()
        let capture = AudioSyncCapture(inputHardware: hardware, microphonePermission: {
            hardware.devices = [.init(id: 77, uid: "usb", channels: 2)]
            hardware.defaultID = 77
        }, makeMicrophoneEngine: { engine })
        try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in }
        XCTAssertEqual(engine.selectedID, 77)
        XCTAssertEqual(engine.operations, ["select", "format", "tap", "start"])
        XCTAssertTrue(capture.isRunning)
        await capture.stop()
        await capture.stop()
        XCTAssertEqual(engine.operations, ["select", "format", "tap", "start", "stop"])
        XCTAssertFalse(capture.isRunning)
    }

    func testDefaultUIDIsFrozenAcrossPermissionSuspension() async throws {
        let hardware = InputHardware()
        let engine = InputEngine()
        let capture = AudioSyncCapture(inputHardware: hardware, microphonePermission: {
            hardware.defaultID = 20
        }, makeMicrophoneEngine: { engine })
        try await capture.start(source: .microphone) { _ in }
        XCTAssertEqual(engine.selectedID, 10)
        await capture.stop()
    }

    func testInputRemovedDuringPermissionDoesNotFallBackOrCreateEngine() async {
        let hardware = InputHardware()
        var engines = 0
        let capture = AudioSyncCapture(inputHardware: hardware, microphonePermission: {
            hardware.devices.removeAll { $0.uid == "usb" }
        }, makeMicrophoneEngine: {
            engines += 1
            return InputEngine()
        })
        do {
            try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in }
            XCTFail("Removed input must fail")
        } catch { XCTAssertEqual(error as? AudioInputError, .unavailable("usb")) }
        XCTAssertEqual(engines, 0)
        XCTAssertFalse(capture.isRunning)
    }

    func testStopDuringPermissionSuspensionPreventsLateEngineCreation() async {
        let suspended = expectation(description: "Waiting for injected permission")
        var resume: CheckedContinuation<Void, Never>?
        var engines = 0
        let capture = AudioSyncCapture(inputHardware: InputHardware(), microphonePermission: {
            await withCheckedContinuation { continuation in
                resume = continuation
                suspended.fulfill()
            }
        }, makeMicrophoneEngine: {
            engines += 1
            return InputEngine()
        })
        let start = Task { try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in } }
        await fulfillment(of: [suspended], timeout: 1)
        await capture.stop()
        resume?.resume()
        do { try await start.value; XCTFail("Superseded start must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engines, 0)
        XCTAssertFalse(capture.isRunning)
        XCTAssertNil(capture.lastError)
    }

    func testSelectionFailureNeverInstallsTapAndCleansUpOnce() async {
        let engine = InputEngine()
        engine.selectionError = AudioInputError.selectionFailed(-12)
        let capture = AudioSyncCapture(inputHardware: InputHardware(), microphonePermission: {}, makeMicrophoneEngine: { engine })
        do {
            try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in }
            XCTFail("Selection must fail")
        } catch { XCTAssertEqual(error as? AudioInputError, .selectionFailed(-12)) }
        XCTAssertEqual(engine.operations, ["select", "stop"])
        XCTAssertFalse(capture.isRunning)
        await capture.stop()
        XCTAssertEqual(engine.operations, ["select", "stop"])
    }

    func testStartFailureRemovesTapAndObserverThroughEngineCleanup() async {
        let engine = InputEngine()
        engine.startError = AudioInputError.selectionFailed(-13)
        let capture = AudioSyncCapture(inputHardware: InputHardware(), microphonePermission: {}, makeMicrophoneEngine: { engine })
        do {
            try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in }
            XCTFail("Engine start must fail")
        } catch { XCTAssertTrue(error is CaptureError) }
        XCTAssertEqual(engine.operations, ["select", "format", "tap", "start", "stop"])
        XCTAssertNil(engine.configurationChanged)
        XCTAssertFalse(capture.isRunning)
    }

    func testUnsupportedFormatFailsBeforeTapOrEngineStart() async {
        let engine = InputEngine()
        engine.format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)!
        let capture = AudioSyncCapture(inputHardware: InputHardware(), microphonePermission: {}, makeMicrophoneEngine: { engine })
        do {
            try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in }
            XCTFail("Integer input must fail")
        } catch { XCTAssertEqual(error as? CaptureError, .unsupportedAudioFormat) }
        XCTAssertEqual(engine.operations, ["select", "format", "stop"])
    }

    func testRuntimeInputChangeDefersCleanupAndRequiresRestart() async throws {
        let engine = InputEngine()
        let capture = AudioSyncCapture(inputHardware: InputHardware(), microphonePermission: {}, makeMicrophoneEngine: { engine })
        try await capture.start(source: .microphone, inputDeviceUID: "usb") { _ in }
        let failed = expectation(description: "Input configuration failure delivered on main")
        let subscription = capture.$lastError.sink { if $0 != nil { failed.fulfill() } }
        let lateChange = try XCTUnwrap(engine.configurationChanged)
        lateChange()
        XCTAssertFalse(engine.operations.contains("stop"), "The audio callback must not stop its own engine")
        await fulfillment(of: [failed], timeout: 1)
        await capture.stop()
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(capture.lastError, CaptureError.microphoneConfigurationChanged.localizedDescription)
        XCTAssertEqual(engine.operations.filter { $0 == "stop" }.count, 1)
        lateChange()
        subscription.cancel()
    }
}

private final class InputListeners: AudioInputPropertyListening {
    var listeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    var removed: [AudioObjectPropertySelector] = []
    var failingSelector: AudioObjectPropertySelector?
    func add(_ selector: AudioObjectPropertySelector, listener: @escaping AudioObjectPropertyListenerBlock) throws {
        if selector == failingSelector { throw AudioInputError.hardwareReadFailed(-17) }
        listeners[selector] = listener
    }
    func remove(_ selector: AudioObjectPropertySelector, listener: @escaping AudioObjectPropertyListenerBlock) {
        removed.append(selector)
        listeners[selector] = nil
    }
    func fire(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        withUnsafePointer(to: &address) { listeners[selector]?(1, $0) }
    }
}

@MainActor
final class AudioInputTopologyTests: XCTestCase {
    func testObserverDeliversOnMainAndInvalidationSuppressesQueuedCallbacks() async throws {
        let hardware = InputListeners()
        let changed = expectation(description: "Input topology notification")
        var notifications = 0
        let observer = try AudioInputTopologyObserver(hardware: hardware) {
            XCTAssertTrue(Thread.isMainThread)
            notifications += 1
            changed.fulfill()
        }
        XCTAssertEqual(Set(hardware.listeners.keys), [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice])
        hardware.fire(kAudioHardwarePropertyDevices)
        await fulfillment(of: [changed], timeout: 1)
        hardware.fire(kAudioHardwarePropertyDefaultInputDevice)
        observer.invalidate()
        observer.invalidate()
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(hardware.removed, [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice])
    }

    func testObserverDeinitRemovesListenersAndRegistrationFailureRollsBack() throws {
        let hardware = InputListeners()
        var observer: AudioInputTopologyObserver? = try AudioInputTopologyObserver(hardware: hardware) {}
        XCTAssertEqual(hardware.listeners.count, 2)
        observer = nil
        XCTAssertNil(observer)
        XCTAssertTrue(hardware.listeners.isEmpty)
        XCTAssertEqual(hardware.removed.count, 2)
        let partial = InputListeners()
        partial.failingSelector = kAudioHardwarePropertyDefaultInputDevice
        XCTAssertThrowsError(try AudioInputTopologyObserver(hardware: partial) {})
        XCTAssertTrue(partial.listeners.isEmpty)
        XCTAssertEqual(partial.removed, [kAudioHardwarePropertyDevices])
    }
}
