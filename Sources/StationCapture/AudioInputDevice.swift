import AudioToolbox
import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Sendable, Hashable {
    /// The persistent CoreAudio device UID, never the transient AudioDeviceID.
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum AudioInputError: Error, LocalizedError, Sendable, Equatable {
    case hardwareReadFailed(OSStatus)
    case unavailable(String?)
    case selectionFailed(OSStatus)
    case selectionDidNotMatch

    public var errorDescription: String? {
        switch self {
        case .hardwareReadFailed(let status):
            return "macOS could not read the audio input devices (\(status))."
        case .unavailable(.some):
            return "The selected audio input is no longer available. Select an input device and start again."
        case .unavailable(.none):
            return "No default audio input is available. Connect or select an input device and start again."
        case .selectionFailed(let status):
            return "macOS could not select the audio input (\(status))."
        case .selectionDidNotMatch:
            return "macOS did not select the requested audio input. Start again."
        }
    }
}

protocol AudioInputHardware {
    func deviceIDs() throws -> [AudioDeviceID]
    func defaultInputID() throws -> AudioDeviceID
    func inputChannelCount(_ id: AudioDeviceID) throws -> UInt32
    func uid(_ id: AudioDeviceID) throws -> String
    func name(_ id: AudioDeviceID) throws -> String
}

struct AudioInputDeviceCatalog {
    let hardware: any AudioInputHardware

    init(hardware: any AudioInputHardware = CoreAudioInputHardware()) {
        self.hardware = hardware
    }

    func availableInputs() throws -> [AudioInputDevice] {
        try snapshot().map(\.device)
    }

    func resolve(uid: String?) throws -> (deviceID: AudioDeviceID, device: AudioInputDevice) {
        // Re-enumerate on every resolution: IDs and capabilities can change after hot-plug.
        let inputs = try snapshot()
        // The default is a real device, not a fallback for a missing pinned UID.
        guard let input = inputs.first(where: { input in
            if let uid { return input.device.id == uid }
            return input.device.isDefault
        }) else { throw AudioInputError.unavailable(uid) }
        return input
    }

    private func snapshot() throws -> [(deviceID: AudioDeviceID, device: AudioInputDevice)] {
        let ids = try hardware.deviceIDs()
        let defaultID = try hardware.defaultInputID()
        var seen = Set<String>()
        var inputs: [(deviceID: AudioDeviceID, device: AudioInputDevice)] = []
        for id in ids where id != kAudioObjectUnknown {
            // A device may disappear during enumeration. Skip that entry, not other inputs.
            guard let channels = try? hardware.inputChannelCount(id), channels > 0,
                  let uid = try? hardware.uid(id), !uid.isEmpty, seen.insert(uid).inserted else { continue }
            let name = (try? hardware.name(id)).flatMap { $0.isEmpty ? nil : $0 } ?? "Audio input"
            inputs.append((id, AudioInputDevice(id: uid, name: name, isDefault: id == defaultID)))
        }
        return inputs.sorted {
            if $0.device.isDefault != $1.device.isDefault { return $0.device.isDefault }
            let order = $0.device.name.localizedStandardCompare($1.device.name)
            return order == .orderedSame ? $0.device.id < $1.device.id : order == .orderedAscending
        }
    }
}

private struct CoreAudioInputHardware: AudioInputHardware {
    func deviceIDs() throws -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0 else {
            throw AudioInputError.hardwareReadFailed(kAudioHardwareBadPropertySizeError)
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty else { return [] }
        try ids.withUnsafeMutableBytes {
            try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!))
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride))
    }

    func defaultInputID() throws -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id))
        return id
    }

    func inputChannelCount(_ id: AudioDeviceID) throws -> UInt32 {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        guard size >= MemoryLayout<UInt32>.size else {
            throw AudioInputError.hardwareReadFailed(kAudioHardwareBadPropertySizeError)
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try Self.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage))
        return try audioInputChannelCount(in: storage, byteCount: Int(size))
    }

    func uid(_ id: AudioDeviceID) throws -> String { try string(id, selector: kAudioDevicePropertyDeviceUID) }
    func name(_ id: AudioDeviceID) throws -> String { try string(id, selector: kAudioObjectPropertyName) }

    private func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = Self.address(selector)
        try Self.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        // Both properties transfer ownership to the caller (AudioHardwareBase.h).
        guard let value else { throw AudioInputError.hardwareReadFailed(kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioInputError.hardwareReadFailed(status) }
    }
}

/// Validate the variable-length list before traversing its input buffers.
func audioInputChannelCount(in storage: UnsafeRawPointer, byteCount: Int) throws -> UInt32 {
    let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    guard byteCount >= offset else { throw AudioInputError.hardwareReadFailed(kAudioHardwareBadPropertySizeError) }
    let count = Int(storage.load(as: UInt32.self))
    guard count <= (byteCount - offset) / MemoryLayout<AudioBuffer>.stride else {
        throw AudioInputError.hardwareReadFailed(kAudioHardwareBadPropertySizeError)
    }
    var channels: UInt32 = 0
    for index in 0..<count {
        let buffer = storage.load(fromByteOffset: offset + index * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self)
        let sum = channels.addingReportingOverflow(buffer.mNumberChannels)
        guard !sum.overflow else { throw AudioInputError.hardwareReadFailed(kAudioHardwareBadPropertySizeError) }
        channels = sum.partialValue
    }
    return channels
}

/// Only the engine owns its audio unit's initialization and disposal lifecycle.
struct AudioUnitInputDeviceSelection {
    typealias Access = (AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, inout AudioDeviceID) -> OSStatus
    let set: Access
    let get: Access

    init(audioUnit: AudioUnit) {
        set = { property, scope, element, id in
            AudioUnitSetProperty(audioUnit, property, scope, element, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        get = { property, scope, element, id in
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            return AudioUnitGetProperty(audioUnit, property, scope, element, &id, &size)
        }
    }

    init(set: @escaping Access, get: @escaping Access) {
        self.set = set
        self.get = get
    }

    func select(_ deviceID: AudioDeviceID) throws {
        var requested = deviceID
        let status = set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &requested)
        guard status == noErr else { throw AudioInputError.selectionFailed(status) }
        try verify(deviceID)
    }

    func verify(_ deviceID: AudioDeviceID) throws {
        var actual = AudioDeviceID(kAudioObjectUnknown)
        let readStatus = get(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual)
        guard readStatus == noErr else { throw AudioInputError.selectionFailed(readStatus) }
        guard actual == deviceID else { throw AudioInputError.selectionDidNotMatch }
    }
}

protocol AudioInputPropertyListening {
    func add(_ selector: AudioObjectPropertySelector, listener: @escaping AudioObjectPropertyListenerBlock) throws
    func remove(_ selector: AudioObjectPropertySelector, listener: @escaping AudioObjectPropertyListenerBlock)
}

private struct CoreAudioInputPropertyListener: AudioInputPropertyListening {
    func add(_ selector: AudioObjectPropertySelector, listener: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = Self.address(selector)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        guard status == noErr else { throw AudioInputError.hardwareReadFailed(status) }
    }

    func remove(_ selector: AudioObjectPropertySelector, listener: @escaping AudioObjectPropertyListenerBlock) {
        var address = Self.address(selector)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Watches device/default-input changes without opening an input or requesting access.
@MainActor
public final class AudioInputTopologyObserver {
    private let registration: AudioInputObservationRegistration

    public convenience init(onChange: @escaping @MainActor @Sendable () -> Void) throws {
        try self.init(hardware: CoreAudioInputPropertyListener(), onChange: onChange)
    }

    init(hardware: any AudioInputPropertyListening, onChange: @escaping @MainActor @Sendable () -> Void) throws {
        registration = try AudioInputObservationRegistration(hardware: hardware, onChange: onChange)
    }

    public func invalidate() { registration.invalidate() }

    deinit { registration.invalidate() }
}

private final class AudioInputObservationRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var selectors: [AudioObjectPropertySelector] = []
    private let hardware: any AudioInputPropertyListening
    private let onChange: @MainActor @Sendable () -> Void
    private var listener: AudioObjectPropertyListenerBlock!

    init(hardware: any AudioInputPropertyListening, onChange: @escaping @MainActor @Sendable () -> Void) throws {
        self.hardware = hardware
        self.onChange = onChange
        listener = { [weak self] _, _ in
            // Removal does not drain previously queued callbacks. Check again on main.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let active = self.active
                self.lock.unlock()
                if active { MainActor.assumeIsolated { self.onChange() } }
            }
        }
        do {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                try hardware.add(selector, listener: listener)
                selectors.append(selector)
            }
        } catch {
            invalidate()
            throw error
        }
    }

    func invalidate() {
        lock.lock()
        active = false
        let registered = selectors
        selectors.removeAll()
        lock.unlock()
        for selector in registered { hardware.remove(selector, listener: listener) }
    }
}
