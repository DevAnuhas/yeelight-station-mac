import AppKit
import Combine
import StationCore
import StationCapture
import SwiftUI

@MainActor
final class DeviceEntry: ObservableObject, Identifiable {
    let id: String
    @Published var device: LightDevice
    @Published var online = false
    @Published var busy = false
    @Published var error: String?
    var confirmedProperties: [String: String]
    init(_ device: LightDevice) { self.device = device; id = device.id; confirmedProperties = device.properties }
    func value(_ name: String, channel: LightChannel) -> String? { device.properties[channel == .background ? "bg_" + name : name] }
}

enum SyncMode: String { case idle, screen, music }

@MainActor
protocol StationAudioCapturing: AnyObject {
    var isRunning: Bool { get }
    var lastError: String? { get }
    var failurePublisher: AnyPublisher<String?, Never> { get }
    func availableAudioInputs() throws -> [AudioInputDevice]
    func observeInputs(onChange: @escaping @MainActor @Sendable () -> Void) throws -> (@MainActor () -> Void)
    func start(source: AudioSource, displayID: UInt32?, inputDeviceUID: String?,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws
    func stop() async
}

extension AudioSyncCapture: StationAudioCapturing {
    var failurePublisher: AnyPublisher<String?, Never> { $lastError.eraseToAnyPublisher() }
    func observeInputs(onChange: @escaping @MainActor @Sendable () -> Void) throws -> (@MainActor () -> Void) {
        let observer = try AudioInputTopologyObserver(onChange: onChange)
        return { observer.invalidate() }
    }
}

@MainActor
final class StationModel: ObservableObject {
    @Published var devices: [DeviceEntry] = []
    @Published var discovered: [LightDevice] = []
    @Published var scanning = false
    @Published var connecting = false
    @Published var error: String?
    @Published var notice: String?
    @Published var config = StationConfiguration()
    @Published var displays: [CaptureDisplay] = []
    @Published var mode: SyncMode = .idle
    @Published var transitioning = false
    @Published var controlling = false
    @Published var colors: [StationCore.RGBColor] = []
    @Published var audioLevel = 0.0
    @Published var audioSource: AudioSource = .system
    @Published var audioInputs: [AudioInputDevice] = []
    @Published var selectedAudioInputUID: String?
    let presets: StationPresets
    let preview: Bool
    let screen = ScreenSyncCapture()
    let audio: any StationAudioCapturing
    private let store: ConfigurationStore
    private var persistenceEnabled = true
    private var connections: [String: LightConnection] = [:]
    private var pollTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var pendingColors: [StationCore.RGBColor]?
    private var activeAssignments: [DeviceAssignment] = []
    private var restoreStates: [SavedLightState] = []
    private var generation = 0
    private var paletteStep = 0
    private var lastBeat = Date.distantPast
    private var previousLevel = 0.0
    private var cleanupTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var deviceSubscriptions = Set<AnyCancellable>()
    @Published private var shuttingDown = false
    private var controlTask: Task<Void, Never>?
    private var controls: [UUID: Task<Void, Never>] = [:]
    private var commandDevices = Set<String>()
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private let displayProvider: (@MainActor () async throws -> [CaptureDisplay])?
    private let notificationCenter: NotificationCenter
    private let realtimeStart: @Sendable (LightConnection, LightChannel) async throws -> Void
    private var invalidateAudioInputObservation: (@MainActor () -> Void)?
    private var displayObserver: NSObjectProtocol?
    private var displayTask: Task<Void, Never>?
    private var displayGeneration = 0
    private var began = false
    private var activeDisplayID: UInt32?
    private var activeAudioInputUID: String?
    private var activeAudioInputUsesDefault = false
    private var startupTask: Task<Void, Never>?
    private var adjustmentTask: Task<Void, Never>?
    private var adjustmentQueue: [AdjustmentKey] = []
    private var queuedAdjustments: [AdjustmentKey: Adjustment] = [:]
    private var desiredAdjustments: [AdjustmentKey: Adjustment] = [:]
    private var adjustmentRevision = 0
    private var propertyRevisions: [AdjustmentKey: Int] = [:]

    init(store: ConfigurationStore = ConfigurationStore(), previewMode: Bool? = nil,
         displayProvider: (@MainActor () async throws -> [CaptureDisplay])? = nil,
         notificationCenter: NotificationCenter = .default,
         audioCapture: (any StationAudioCapturing)? = nil,
         realtimeStart: @escaping @Sendable (LightConnection, LightChannel) async throws -> Void = { try await $0.startRealtime(channel: $1) }) {
        self.store = store
        self.displayProvider = displayProvider
        self.notificationCenter = notificationCenter
        self.audio = audioCapture ?? AudioSyncCapture()
        self.realtimeStart = realtimeStart
        preview = previewMode ?? ProcessInfo.processInfo.arguments.contains("--demo")
        do { presets = try StationPresets.load() }
        catch { fatalError("Cannot load bundled Station presets: \(error)") }
        if preview {
            config.devices = [LightDevice(id: "preview-bar", name: "Monitor Light Bar Pro", model: "lamp15", host: "192.0.2.1", support: ["udp_sess_new", "bg_set_rgb", "set_ct_abx"], properties: ["power":"on", "bright":"80", "ct":"4000", "bg_power":"on", "bg_bright":"65", "bg_rgb":"5680127"])]
        } else {
            do { config = try store.load() }
            catch { self.error = "Couldn’t load settings: \(error.localizedDescription)"; persistenceEnabled = false }
        }
        devices = config.devices.map(DeviceEntry.init)
        for entry in devices {
            if config.assignments[entry.id] == nil { config.assignments[entry.id] = DeviceAssignment(deviceID: entry.id, channel: entry.device.defaultChannel) }
            if preview { entry.online = true }
        }
        observeDeviceStatus()
        observeCaptureFailures()
    }

    private func observeDeviceStatus() {
        // Cards observe individual entries; aggregate sidebar/status views observe
        // the model. Forward child changes and detach removed lights.
        $devices.sink { [weak self] entries in
            guard let self else { return }
            self.deviceSubscriptions.removeAll()
            for entry in entries {
                entry.objectWillChange.sink { [weak self] in
                    self?.objectWillChange.send()
                }.store(in: &self.deviceSubscriptions)
            }
        }.store(in: &subscriptions)
    }

    private func observeCaptureFailures() {
        screen.$lastError.compactMap { $0 }.sink { [weak self] message in
            guard let self, !self.shuttingDown, self.mode == .screen else { return }
            self.error = message
            let ticket = self.generation
            Task { [weak self] in if self?.generation == ticket { await self?.stopSync() } }
        }.store(in: &subscriptions)
        audio.failurePublisher.compactMap { $0 }.sink { [weak self] message in
            guard let self, !self.shuttingDown, self.mode == .music else { return }
            self.error = message
            let ticket = self.generation
            Task { [weak self] in if self?.generation == ticket { await self?.stopSync() } }
        }.store(in: &subscriptions)
    }

    var layout: ScreenLayout { presets.layouts.first { $0.id == config.layoutID } ?? presets.layouts[0] }
    var palette: MusicPalette { presets.palettes.first { $0.id == config.paletteID } ?? presets.palettes[0] }
    var outputs: [DeviceAssignment] { devices.compactMap { config.assignments[$0.id] }.filter(\.enabled) }
    var onlineCount: Int { devices.filter(\.online).count }
    var active: Bool { mode != .idle }
    var isShuttingDown: Bool { shuttingDown }
    var selectedDisplay: CaptureDisplay? { displays.first { $0.id == config.displayID } }
    var selectedAudioInput: AudioInputDevice? { audioInput(uid: selectedAudioInputUID) }
    private var systemAudioDisplay: CaptureDisplay? { displays.first { $0.id == CGMainDisplayID() } ?? displays.first }
    private func audioInput(uid: String?) -> AudioInputDevice? {
        if let uid { return audioInputs.first { $0.id == uid } }
        return audioInputs.first { $0.isDefault }
    }
    func requiresDisplay(for target: SyncMode) -> Bool { target == .screen }
    func displayReady(for target: SyncMode, displayID: UInt32? = nil) -> Bool {
        if target == .music { return audioSource != .system || systemAudioDisplay != nil }
        return !requiresDisplay(for: target) || displays.contains { $0.id == (displayID ?? config.displayID) }
    }
    func canStart(_ target: SyncMode, displayID: UInt32? = nil) -> Bool {
        canStart(target, displayID: displayID, audioSource: audioSource, inputDeviceUID: selectedAudioInputUID)
    }
    func canStart(_ target: SyncMode, displayID: UInt32? = nil, audioSource source: AudioSource, inputDeviceUID: String? = nil) -> Bool {
        guard target != .idle, target != mode, !transitioning, !controlling, !scanning, !preview, !shuttingDown, !outputs.isEmpty else { return false }
        if target == .music { return source == .system ? systemAudioDisplay != nil : audioInput(uid: inputDeviceUID) != nil }
        return displayReady(for: target, displayID: displayID)
    }
    @discardableResult func selectAudioInput(uid: String?) -> Bool {
        guard !shuttingDown, audioInput(uid: uid) != nil else { return false }
        selectedAudioInputUID = uid
        return true
    }
    @discardableResult func selectDisplay(_ id: UInt32) -> Bool {
        guard !shuttingDown, displays.contains(where: { $0.id == id }) else { return false }
        config.displayID = id; save(); return true
    }
    func setBrightness(_ entry: DeviceEntry, channel: LightChannel, value: Int) {
        queueAdjustment(entry, channel: channel, property: "bright", value: min(100, max(1, value)), command: LightCommands.brightness(value, channel: channel))
    }
    func setTemperature(_ entry: DeviceEntry, channel: LightChannel, value: Int) {
        queueAdjustment(entry, channel: channel, property: "ct", value: min(6500, max(1700, value)), command: LightCommands.temperature(value, channel: channel), colorMode: "2")
    }
    func setColor(_ entry: DeviceEntry, channel: LightChannel, value: StationCore.RGBColor) {
        queueAdjustment(entry, channel: channel, property: "rgb", value: value.packed, command: LightCommands.color(value, channel: channel), colorMode: "1")
    }
    func assignment(for entry: DeviceEntry) -> DeviceAssignment { config.assignments[entry.id] ?? DeviceAssignment(deviceID: entry.id, channel: entry.device.defaultChannel) }
    func updateAssignment(_ entry: DeviceEntry, _ change: (inout DeviceAssignment) -> Void) {
        var value = assignment(for: entry); change(&value); config.assignments[entry.id] = value; save()
    }
    func save() {
        guard !preview, persistenceEnabled else { return }
        config.devices = devices.map { entry in
            var device = entry.device; device.properties = entry.confirmedProperties; return device
        }
        do { try store.save(config) } catch { self.error = "Couldn’t save settings: \(error.localizedDescription)" }
    }
    func connection(_ entry: DeviceEntry) -> LightConnection {
        if let value = connections[entry.id] { return value }
        var device = entry.device; device.properties = entry.confirmedProperties
        let value = LightConnection(device: device); connections[entry.id] = value; return value
    }
    func begin() {
        guard !shuttingDown, !began else { return }
        began = true
        displayObserver = notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.loadDisplays() }
        }
        displayTask = Task { [weak self] in await self?.loadDisplays() }
        loadAudioInputs()
        do {
            invalidateAudioInputObservation = try audio.observeInputs { [weak self] in self?.loadAudioInputs() }
        } catch { if !shuttingDown { self.error = error.localizedDescription } }
        guard !preview else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.active && !self.transitioning { await self.refreshAll() }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
    func refreshAll() async { for entry in devices { if Task.isCancelled { return }; await refresh(entry) } }
    func refresh(_ entry: DeviceEntry) async {
        guard !preview, !shuttingDown else { return }
        if let existing = refreshTasks[entry.id] { await existing.value; return }
        guard !entry.busy, !desiredAdjustments.keys.contains(where: { $0.deviceID == entry.id }) else { return }
        entry.busy = true
        let host = entry.device.host, port = entry.device.port
        let revision = adjustmentRevision
        let operation = Task { [self] in
            do {
                let values = try await connection(entry).properties(includeCached: false)
                guard !shuttingDown, !Task.isCancelled, entry.device.host == host, entry.device.port == port else { return }
                mergeProperties(values, into: entry, observedAt: revision); entry.online = true; entry.error = nil
            } catch {
                guard !shuttingDown, !Task.isCancelled, entry.device.host == host, entry.device.port == port else { return }
                entry.online = false; entry.error = error.localizedDescription
            }
        }
        refreshTasks[entry.id] = operation
        await operation.value
        refreshTasks.removeValue(forKey: entry.id); entry.busy = commandDevices.contains(entry.id)
    }
    private func queueAdjustment(_ entry: DeviceEntry, channel: LightChannel, property: String, value: Int,
                                 command: (String, [JSONValue]), colorMode: String? = nil) {
        guard !shuttingDown, devices.contains(where: { $0 === entry }), channel != .background || entry.device.hasBackground else { return }
        guard !scanning, !transitioning, !controlling, !entry.busy || refreshTasks[entry.id] != nil else {
            error = "Wait for the current operation to finish before adjusting \(entry.device.displayName)."
            recomposeProperties(entry); return
        }
        if preview { notice = "Preview mode: commands stay on this Mac."; return }
        let prefix = channel == .background ? "bg_" : ""
        let key = AdjustmentKey(deviceID: entry.id, property: prefix + property)
        adjustmentRevision += 1
        var properties = [key.property: String(value)]
        if let colorMode { properties[prefix + "color_mode"] = colorMode }
        let intent = Adjustment(entry: entry, command: command, properties: properties, revision: adjustmentRevision)
        for name in properties.keys { propertyRevisions[AdjustmentKey(deviceID: entry.id, property: name)] = intent.revision }
        desiredAdjustments[key] = intent
        queuedAdjustments[key] = intent
        adjustmentQueue.removeAll { $0 == key }; adjustmentQueue.append(key)
        entry.device.properties.merge(properties) { _, new in new }
        guard adjustmentTask == nil else { return }
        let previous = controlTask
        let operation = Task { [self] in
            await previous?.value
            while !Task.isCancelled, !shuttingDown, !adjustmentQueue.isEmpty {
                let key = adjustmentQueue.removeFirst()
                guard let intent = queuedAdjustments.removeValue(forKey: key) else { continue }
                await performAdjustment(intent, key: key)
            }
            adjustmentTask = nil
            if controls.isEmpty { controlTask = nil }
        }
        adjustmentTask = operation; controlTask = operation
    }
    private func performAdjustment(_ intent: Adjustment, key: AdjustmentKey) async {
        let entry = intent.entry
        await refreshTasks[entry.id]?.value
        guard !shuttingDown, !Task.isCancelled, devices.contains(where: { $0 === entry }) else { return }
        if active { await stopSync(cancelStartup: false) } else { await cleanupTask?.value }
        guard !shuttingDown, !Task.isCancelled else { return }
        // A value waiting for polling/cleanup has not entered the transport yet.
        // Let its newer replacement keep its position among surviving intents.
        guard desiredAdjustments[key]?.revision == intent.revision else { return }
        var failure: Error?
        do {
            _ = try await connection(entry).request(method: intent.command.0, params: intent.command.1)
            guard !shuttingDown, !Task.isCancelled else { return }
            // An ACK confirms the submitted target even if subsequent inspection
            // fails. A rejected/uncertain command never becomes confirmed state.
            entry.confirmedProperties.merge(intent.properties) { _, new in new }
        }
        catch { failure = error }
        guard !shuttingDown, !Task.isCancelled else { return }
        // The in-flight command is immutable. Its read-back must not erase a
        // newer desired value, even if that value arrived before this query.
        let revision = adjustmentRevision
        var readBack: [String: String]?
        do { readBack = try await connection(entry).properties(includeCached: false) }
        catch { if failure == nil { failure = error } }
        guard !shuttingDown, !Task.isCancelled else { return }
        if desiredAdjustments[key]?.revision == intent.revision { desiredAdjustments.removeValue(forKey: key) }
        if let readBack { mergeProperties(readBack, into: entry, observedAt: revision); entry.online = true }
        else { recomposeProperties(entry) }
        if let failure {
            entry.error = failure.localizedDescription
            error = "\(entry.device.displayName): \(failure.localizedDescription)"
        } else { entry.error = nil }
        save()
    }
    private func mergeProperties(_ values: [String: String], into entry: DeviceEntry, observedAt revision: Int) {
        let pending = desiredAdjustments.values.filter { $0.entry === entry }
        let accepted = values.filter { name, _ in
            let key = AdjustmentKey(deviceID: entry.id, property: name)
            return (propertyRevisions[key] ?? 0) <= revision && !pending.contains { $0.properties[name] != nil }
        }
        entry.confirmedProperties.merge(accepted) { _, new in new }
        recomposeProperties(entry)
    }
    private func recomposeProperties(_ entry: DeviceEntry) {
        var values = entry.confirmedProperties
        for intent in desiredAdjustments.values.filter({ $0.entry === entry }).sorted(by: { $0.revision < $1.revision }) {
            values.merge(intent.properties) { _, new in new }
        }
        entry.device.properties = values
    }
    func scan() async {
        guard !preview, !scanning, !controlling, !transitioning, !shuttingDown else { return }
        scanning = true; error = nil; notice = nil; defer { scanning = false }
        await adjustmentTask?.value
        guard !shuttingDown else { return }
        do {
            let found = try await YeelightDiscovery.scan(timeout: 3)
            guard !shuttingDown else { return }
            discovered = found.filter { d in !devices.contains { $0.id == d.id || $0.device.host == d.host } }
            if found.isEmpty {
                notice = "No lights replied yet. If macOS just asked for Local Network access, allow it and choose Discover again. Otherwise, check LAN Control and that your Mac and light share the same network."
            } else if discovered.isEmpty {
                notice = "The lights found on your network are already in My Lights."
            }
            for d in found {
                if let entry = devices.first(where: { $0.id == d.id || $0.device.host == d.host }) {
                    let endpointChanged = entry.device.host != d.host || entry.device.port != d.port
                    let capabilitiesChanged = entry.device.support != d.support
                    if endpointChanged && (active || transitioning) { await stopSync() }
                    guard !shuttingDown else { return }
                    let old: LightConnection?
                    if endpointChanged || (capabilitiesChanged && !active) { old = connections.removeValue(forKey: entry.id) }
                    else { old = nil }
                    // Endpoint update and cache invalidation must be atomic before close suspends.
                    entry.device.host = d.host; entry.device.port = d.port; entry.device.support = d.support
                    await old?.close()
                    guard !shuttingDown else { return }
                    if !active { await refresh(entry) }
                }
            }
            save()
        } catch { self.error = error.localizedDescription }
    }
    func add(_ device: LightDevice) async {
        guard !shuttingDown, !devices.contains(where: { $0.id == device.id || $0.device.host == device.host }) else { return }
        let entry = DeviceEntry(device); devices.append(entry)
        config.assignments[entry.id] = DeviceAssignment(deviceID: entry.id, channel: device.defaultChannel)
        discovered.removeAll { $0.id == device.id }; save(); await refresh(entry)
    }
    func addByIP(_ host: String, model: String) async -> Bool {
        guard !connecting, !preview, !shuttingDown else { return false }
        connecting = true; error = nil; defer { connecting = false }
        do {
            if let match = devices.first(where: { $0.device.host == host }) { await refresh(match); return match.online }
            let found = (try? await YeelightDiscovery.scan(timeout: 2, host: host)) ?? []
            guard !shuttingDown else { return false }
            if let d = found.first { await add(d); return true }
            let d = LightDevice(id: "manual-" + host, name: "", model: model, host: host)
            let probe = LightConnection(device: d)
            let values: [String: String]
            do { values = try await probe.properties(includeCached: false) } catch { await probe.close(); throw error }
            await probe.close()
            guard !shuttingDown else { return false }
            var verified = d; verified.properties = values
            if let actualModel = values["model"], !actualModel.isEmpty { verified.model = actualModel }
            await add(verified)
            notice = "Connected with TCP controls. Discovery returned no capabilities; allow Local Network access and discover again before starting sync."
            return true
        } catch { self.error = "Couldn’t reach \(host). \(error.localizedDescription) Check LAN Control and this Mac’s network."; return false }
    }
    func remove(_ entry: DeviceEntry) async {
        guard !shuttingDown, !controlling, !transitioning else { return }
        transitioning = true; defer { transitioning = false }
        await adjustmentTask?.value
        guard !shuttingDown else { return }
        await stopSync()
        guard !shuttingDown else { return }
        if let conn = connections.removeValue(forKey: entry.id) { await conn.close() }
        devices.removeAll { $0.id == entry.id }; config.assignments.removeValue(forKey: entry.id); save()
    }
    func run(_ entry: DeviceEntry, commands: [(String, [JSONValue])], duringScene: Bool = false) async {
        guard !shuttingDown, !scanning, (!transitioning || duringScene) else { return }
        let refresh = refreshTasks[entry.id]
        guard !commandDevices.contains(entry.id), !entry.busy || refresh != nil else {
            error = "A command for \(entry.device.displayName) is still pending. Try again when it finishes."; return
        }
        if preview { notice = "Preview mode: commands stay on this Mac."; return }
        commandDevices.insert(entry.id)
        entry.busy = true; controlling = true
        let previous = controlTask
        let operationID = UUID()
        let operation = Task { [self] in
            await previous?.value
            await refresh?.value
            guard !shuttingDown, !Task.isCancelled else { return }
            entry.busy = true
            if active { await stopSync(cancelStartup: false) } else { await cleanupTask?.value }
            guard !shuttingDown, !Task.isCancelled else { return }
            do {
                for cmd in commands {
                    guard !shuttingDown, !Task.isCancelled else { return }
                    _ = try await connection(entry).request(method: cmd.0, params: cmd.1)
                }
                guard !shuttingDown, !Task.isCancelled else { return }
                entry.error = nil; entry.online = true
                let values = try await connection(entry).properties(includeCached: false)
                guard !shuttingDown, !Task.isCancelled else { return }
                mergeProperties(values, into: entry, observedAt: adjustmentRevision); save()
            } catch {
                if !shuttingDown && !(error is CancellationError) {
                    entry.error = error.localizedDescription
                    self.error = "\(entry.device.displayName): \(error.localizedDescription)"
                }
            }
        }
        controls[operationID] = operation; controlTask = operation
        await operation.value
        controls.removeValue(forKey: operationID); commandDevices.remove(entry.id)
        controlling = !controls.isEmpty; entry.busy = refreshTasks[entry.id] != nil
        if controls.isEmpty { controlTask = nil }
    }
    func apply(_ scene: ScenePreset) async {
        guard !transitioning, !controlling, !scanning, !shuttingDown else { return }
        transitioning = true; defer { transitioning = false }
        await adjustmentTask?.value
        guard !shuttingDown else { return }
        await stopSync()
        guard !outputs.isEmpty else { error = "Add a light and enable it in Sync routing first."; return }
        do {
            // Validate the whole scene before the first device write.
            let actions = try outputs.compactMap { a -> (DeviceEntry, [(String, [JSONValue])])? in
                guard let entry = devices.first(where: { $0.id == a.deviceID }) else { return nil }
                let adjusted = try SceneCompatibility.adapted(scene, device: entry.device, channel: a.channel)
                return (entry, LightCommands.scene(adjusted, channel: a.channel))
            }
            for (entry, commands) in actions {
                guard !shuttingDown else { return }
                await run(entry, commands: commands, duringScene: true)
            }
        } catch { self.error = error.localizedDescription }
    }
    func saveScene(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !outputs.isEmpty, config.savedScenes.count < 256 else { return }
        let actions = outputs.compactMap { a -> SavedLightState? in
            guard let entry = devices.first(where: { $0.id == a.deviceID }) else { return nil }
            return SavedLightState(deviceID: a.deviceID, channel: a.channel, properties: entry.confirmedProperties)
        }
        config.savedScenes.append(SavedScene(name: String(trimmed.prefix(80)), actions: actions)); save()
    }
    func applySaved(_ scene: SavedScene) async {
        guard !transitioning, !controlling, !scanning, !shuttingDown else { return }
        transitioning = true; defer { transitioning = false }
        await adjustmentTask?.value
        guard !shuttingDown else { return }
        await stopSync()
        for state in scene.actions { guard !shuttingDown else { return }; if let entry = devices.first(where: { $0.id == state.deviceID }) { await run(entry, commands: restoreCommands(state), duringScene: true) } }
    }
    func loadDisplays() async {
        do { try await updateDisplays() }
        catch { if !shuttingDown && !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func loadAudioInputs() {
        do { try updateAudioInputs() }
        catch { if !shuttingDown && !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    private func updateAudioInputs(stopUnavailableCapture: Bool = true) throws {
        guard !shuttingDown, !Task.isCancelled else { throw CancellationError() }
        do { audioInputs = try audio.availableAudioInputs() }
        catch {
            audioInputs = []
            if stopUnavailableCapture { stopUnavailableAudioInput() }
            throw error
        }
        if stopUnavailableCapture { stopUnavailableAudioInput() }
    }
    private func stopUnavailableAudioInput() {
        guard let activeAudioInputUID else { return }
        if !audioInputs.contains(where: { $0.id == activeAudioInputUID }) {
            error = "The audio input used for Music Flow disconnected. Choose an available audio input and start again."
        } else if activeAudioInputUsesDefault, audioInput(uid: nil)?.id != activeAudioInputUID {
            error = "The default audio input changed. Start Music Flow again to use the new default."
        } else { return }
        let ticket = generation
        Task { [weak self] in
            guard let self, self.generation == ticket, !self.shuttingDown else { return }
            await self.stopSync()
        }
    }
    private func updateDisplays(stopUnavailableCapture: Bool = true, reconcileSelection: Bool = true) async throws {
        guard !shuttingDown else { throw CancellationError() }
        displayGeneration += 1; let ticket = displayGeneration
        let available: [CaptureDisplay]
        do {
            if let displayProvider { available = try await displayProvider() }
            else { available = try await screen.availableDisplays() }
        }
        catch {
            if ticket == displayGeneration && !shuttingDown { displays = [] }
            throw error
        }
        guard !shuttingDown, !Task.isCancelled, ticket == displayGeneration else { throw CancellationError() }
        displays = available
        if reconcileSelection, selectedDisplay == nil {
            let old = config.displayID
            config.displayID = displays.first?.id
            if old != config.displayID { save() }
        }
        if stopUnavailableCapture, let activeDisplayID, !displays.contains(where: { $0.id == activeDisplayID }) {
            error = mode == .music ? "The display needed by System Audio disconnected. Start Music Flow again when a display is available." : "The display used for sync disconnected. Choose a display and start again."
            await stopSync()
        }
    }
    func start(_ target: SyncMode) async {
        guard target != .idle, target != mode, !transitioning, !controlling, !scanning, !preview, !shuttingDown else {
            if preview { notice = "Connect a real light to start live sync." }; return
        }
        // Freeze user intent before the first suspension. Refresh may reconcile a
        // stale picker, but this Start must never silently capture its replacement.
        let displayID = target == .screen ? config.displayID : nil, source = audioSource
        let usesDefaultAudioInput = target == .music && source == .microphone && selectedAudioInputUID == nil
        let inputDeviceUID: String?
        if target == .music, source == .microphone {
            do {
                try updateAudioInputs(stopUnavailableCapture: false)
                guard let selected = selectedAudioInput else {
                    throw StationError.unavailable("Choose an available audio input before starting Music Flow.")
                }
                inputDeviceUID = selected.id
            } catch { if !shuttingDown && !(error is CancellationError) { self.error = error.localizedDescription }; return }
        } else { inputDeviceUID = nil }
        transitioning = true
        let operation = Task { [self] in
            await performStart(target, displayID: displayID, source: source, inputDeviceUID: inputDeviceUID, usesDefaultAudioInput: usesDefaultAudioInput)
        }
        startupTask = operation
        await operation.value
        startupTask = nil; transitioning = false
    }
    private func performStart(_ target: SyncMode, displayID: UInt32?, source: AudioSource, inputDeviceUID: String?, usesDefaultAudioInput: Bool) async {
        error = nil
        let needsDisplay = target == .screen || (target == .music && source == .system)
        var captureDisplayID = displayID
        func validateSources() throws {
            if needsDisplay && !displays.contains(where: { $0.id == captureDisplayID }) {
                let message = target == .music ? "System Audio is unavailable because no capture display is available." : "Choose an available display before starting sync."
                throw StationError.unavailable(message)
            }
            if target == .music, source == .microphone {
                try updateAudioInputs(stopUnavailableCapture: false)
                guard let inputDeviceUID, audioInputs.contains(where: { $0.id == inputDeviceUID }) else {
                    throw StationError.unavailable("The selected audio input is no longer available. Choose an available audio input and start again.")
                }
                if usesDefaultAudioInput, audioInput(uid: nil)?.id != inputDeviceUID {
                    throw StationError.unavailable("The default audio input changed. Start Music Flow again to use the new default.")
                }
            }
        }
        let assignments = outputs
        guard !assignments.isEmpty else { error = "Add a light and enable it in Sync routing first."; return }
        var beganStartup = false
        do {
            if needsDisplay {
                try await updateDisplays(stopUnavailableCapture: false, reconcileSelection: target == .screen)
                if target == .music { captureDisplayID = systemAudioDisplay?.id }
            }
            try validateSources()
            try Task.checkCancellation()
            // A scene or Start is a barrier after all previously accepted edits,
            // including their read-back. No new edits enter while transitioning.
            await adjustmentTask?.value
            try Task.checkCancellation()
            if needsDisplay { try await updateDisplays(stopUnavailableCapture: false, reconcileSelection: target == .screen) }
            try validateSources()
            guard !shuttingDown else { throw CancellationError() }
            await stopSync(cancelStartup: false)
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            if needsDisplay { try await updateDisplays(stopUnavailableCapture: false, reconcileSelection: target == .screen) }
            try validateSources()
            generation += 1; let ticket = generation
            activeDisplayID = needsDisplay ? captureDisplayID : nil
            activeAudioInputUID = target == .music ? inputDeviceUID : nil
            activeAudioInputUsesDefault = usesDefaultAudioInput
            beganStartup = true
            for a in assignments {
                guard let entry = devices.first(where: { $0.id == a.deviceID }) else { continue }
                try ensureCurrent(ticket)
                try validateSources()
                let revision = adjustmentRevision
                let current = try await connection(entry).properties(includeCached: false)
                try ensureCurrent(ticket)
                try validateSources()
                mergeProperties(current, into: entry, observedAt: revision)
                restoreStates.append(SavedLightState(deviceID: a.deviceID, channel: a.channel, properties: current))
                activeAssignments.append(a)
                try await realtimeStart(connection(entry), a.channel)
                try ensureCurrent(ticket)
                try validateSources()
            }
            if needsDisplay { try await updateDisplays(stopUnavailableCapture: false, reconcileSelection: target == .screen) }
            try validateSources()
            try ensureCurrent(ticket)
            if target == .screen, let captureDisplayID {
                try await screen.start(displayID: captureDisplayID, zones: layout.zones, interval: config.frameInterval) { [weak self] colors in
                    guard let self, !self.shuttingDown, self.generation == ticket else { return }; self.colors = colors; self.queueColors(colors)
                }
            } else {
                try await audio.start(source: source, displayID: captureDisplayID, inputDeviceUID: inputDeviceUID) { [weak self] level in
                    guard let self, !self.shuttingDown, self.generation == ticket else { return }; self.receiveAudio(level)
                }
            }
            try ensureCurrent(ticket)
            try validateSources()
            for a in assignments {
                if let entry = devices.first(where: { $0.id == a.deviceID }) {
                    let command = LightCommands.power(true, channel: a.channel)
                    _ = try await connection(entry).request(method: command.0, params: command.1)
                    try ensureCurrent(ticket)
                    try validateSources()
                }
            }
            guard target == .screen ? screen.isRunning : audio.isRunning else {
                throw StationError.unavailable(screen.lastError ?? audio.lastError ?? "Capture stopped before it became ready.")
            }
            mode = target; save()
        } catch {
            if beganStartup { await stopSync(cancelStartup: false) }
            if !(error is CancellationError) && !shuttingDown { self.error = error.localizedDescription }
        }
    }
    private func ensureCurrent(_ ticket: Int) throws {
        guard generation == ticket, !shuttingDown, !Task.isCancelled else { throw CancellationError() }
        if let activeDisplayID, !displays.contains(where: { $0.id == activeDisplayID }) {
            throw StationError.unavailable("The display used for sync disconnected.")
        }
        if let activeAudioInputUID, !audioInputs.contains(where: { $0.id == activeAudioInputUID }) {
            throw StationError.unavailable("The audio input used for Music Flow disconnected.")
        }
    }
    func stopSync(cancelStartup: Bool = true) async {
        if cancelStartup { startupTask?.cancel() }
        generation += 1; mode = .idle; pendingColors = nil; activeDisplayID = nil; activeAudioInputUID = nil; activeAudioInputUsesDefault = false
        let oldTask = outputTask; outputTask = nil; oldTask?.cancel()
        let old = activeAssignments; activeAssignments = []
        let restore = restoreStates; restoreStates = []; audioLevel = 0
        let previousCleanup = cleanupTask
        let shouldRestore = config.restoreOnStop && !preview
        let cleanup = Task { [self] in
            await previousCleanup?.value
            await screen.stop(); await audio.stop(); await oldTask?.value
            for a in old { if let conn = connections[a.deviceID] { await conn.stopRealtime() } }
            if shouldRestore {
                for state in restore {
                    guard let entry = devices.first(where: { $0.id == state.deviceID }), let existing = connections[state.deviceID] else { continue }
                    do {
                        for cmd in restoreCommands(state) { _ = try await existing.request(method: cmd.0, params: cmd.1) }
                    } catch { if !shuttingDown { self.error = "Stopped sync; couldn’t restore \(entry.device.displayName): \(error.localizedDescription)" } }
                }
            }
        }
        cleanupTask = cleanup
        await cleanup.value
    }
    private func queueColors(_ newColors: [StationCore.RGBColor]) {
        guard !activeAssignments.isEmpty else { return }
        pendingColors = newColors
        guard outputTask == nil else { return }
        let ticket = generation
        outputTask = Task { [weak self] in
            guard let self else { return }
            while let frame = self.pendingColors, !Task.isCancelled, self.generation == ticket {
                self.pendingColors = nil
                for a in self.activeAssignments {
                    guard !Task.isCancelled, self.generation == ticket, let e = self.devices.first(where: { $0.id == a.deviceID }), !frame.isEmpty else { continue }
                    let index = max(0, min(frame.count - 1, a.zone))
                    do { try await self.connection(e).sendRealtime(colors: [frame[index]], channel: a.channel, brightness: Int(self.config.syncBrightness)) }
                    catch {
                        guard !self.shuttingDown, !Task.isCancelled, self.generation == ticket else { return }
                        self.error = "Sync stopped: \(e.device.displayName): \(error.localizedDescription)"
                        // Defer stopping until this output task has returned; stopSync awaits it.
                        Task { [weak self] in if self?.generation == ticket { await self?.stopSync() } }
                        self.pendingColors = nil; self.outputTask = nil; return
                    }
                }
            }
            self.outputTask = nil
        }
    }
    private func receiveAudio(_ input: Double) {
        let level = max(0, min(1, input * config.sensitivity)); audioLevel = level
        if level > 0.3 && level > previousLevel * 1.18 && Date().timeIntervalSince(lastBeat) > 0.25 {
            paletteStep = (paletteStep + 1) % max(1, palette.colors.count); lastBeat = Date()
        }
        previousLevel = level
        let base = palette.colors
        guard !base.isEmpty else { return }
        let frame = (0..<max(layout.zones.count, devices.count)).map { StationCore.RGBColor(packed: base[($0 + paletteStep) % base.count]).scaled(level) }
        colors = frame; queueColors(frame)
    }
    private func restoreCommands(_ state: SavedLightState) -> [(String, [JSONValue])] {
        let p = state.properties; let prefix = state.channel == .background ? "bg_" : ""
        var result: [(String, [JSONValue])] = []
        if (p[prefix + "color_mode"] == "2" || (state.channel == .main && devices.first(where: { $0.id == state.deviceID })?.device.hasBackground == true)), let ct = p[prefix + "ct"].flatMap(Int.init), ct > 0 {
            result.append(LightCommands.temperature(ct, channel: state.channel))
        } else if !(state.channel == .main && devices.first(where: { $0.id == state.deviceID })?.device.hasBackground == true), let rgb = p[prefix + "rgb"].flatMap(Int.init), rgb > 0 {
            result.append(LightCommands.color(StationCore.RGBColor(packed: rgb), channel: state.channel))
        }
        if let bright = p[prefix + "bright"].flatMap(Int.init), bright > 0 { result.append(LightCommands.brightness(bright, channel: state.channel)) }
        if let on = p[prefix + "power"] { result.append(LightCommands.power(on == "on", channel: state.channel)) }
        return result
    }
    func shutdown() async {
        shuttingDown = true; pollTask?.cancel(); displayTask?.cancel(); startupTask?.cancel(); adjustmentTask?.cancel()
        if let displayObserver { notificationCenter.removeObserver(displayObserver); self.displayObserver = nil }
        invalidateAudioInputObservation?(); invalidateAudioInputObservation = nil
        adjustmentQueue.removeAll(); queuedAdjustments.removeAll(); desiredAdjustments.removeAll()
        for entry in devices { recomposeProperties(entry) }
        for operation in controls.values { operation.cancel() }
        for operation in refreshTasks.values { operation.cancel() }
        await displayTask?.value
        await startupTask?.value
        await adjustmentTask?.value
        await pollTask?.value
        for operation in Array(refreshTasks.values) { await operation.value }
        for operation in Array(controls.values) { await operation.value }
        await stopSync()
        for connection in connections.values { await connection.close() }
    }
}
