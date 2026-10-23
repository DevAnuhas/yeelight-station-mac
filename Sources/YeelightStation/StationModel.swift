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
    init(_ device: LightDevice) { self.device = device; id = device.id }
    func value(_ name: String, channel: LightChannel) -> String? { device.properties[channel == .background ? "bg_" + name : name] }
}

enum SyncMode: String { case idle, screen, music }

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
    let presets: StationPresets
    let preview: Bool
    let screen = ScreenSyncCapture()
    let audio = AudioSyncCapture()
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
    private var shuttingDown = false
    private var controlTask: Task<Void, Never>?
    private var controls: [UUID: Task<Void, Never>] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]

    init(store: ConfigurationStore = ConfigurationStore(), previewMode: Bool? = nil) {
        self.store = store
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
            guard let self, self.mode == .screen else { return }
            self.error = message
            let ticket = self.generation
            Task { [weak self] in if self?.generation == ticket { await self?.stopSync() } }
        }.store(in: &subscriptions)
        audio.$lastError.compactMap { $0 }.sink { [weak self] message in
            guard let self, self.mode == .music else { return }
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
    func assignment(for entry: DeviceEntry) -> DeviceAssignment { config.assignments[entry.id] ?? DeviceAssignment(deviceID: entry.id, channel: entry.device.defaultChannel) }
    func updateAssignment(_ entry: DeviceEntry, _ change: (inout DeviceAssignment) -> Void) {
        var value = assignment(for: entry); change(&value); config.assignments[entry.id] = value; save()
    }
    func save() {
        guard !preview, persistenceEnabled else { return }
        config.devices = devices.map(\.device)
        do { try store.save(config) } catch { self.error = "Couldn’t save settings: \(error.localizedDescription)" }
    }
    func connection(_ entry: DeviceEntry) -> LightConnection {
        if let value = connections[entry.id] { return value }
        let value = LightConnection(device: entry.device); connections[entry.id] = value; return value
    }
    func begin() {
        guard !preview, pollTask == nil else { return }
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
        guard !entry.busy else { return }
        entry.busy = true
        let host = entry.device.host, port = entry.device.port
        let operation = Task { [self] in
            do {
                let values = try await connection(entry).properties()
                guard !shuttingDown, !Task.isCancelled, entry.device.host == host, entry.device.port == port else { return }
                entry.device.properties.merge(values) { _, new in new }; entry.online = true; entry.error = nil
            } catch {
                guard !shuttingDown, !Task.isCancelled, entry.device.host == host, entry.device.port == port else { return }
                entry.online = false; entry.error = error.localizedDescription
            }
        }
        refreshTasks[entry.id] = operation
        await operation.value
        refreshTasks.removeValue(forKey: entry.id); entry.busy = false
    }
    func scan() async {
        guard !preview, !scanning, !controlling, !transitioning, !shuttingDown else { return }
        scanning = true; error = nil; notice = nil; defer { scanning = false }
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
            do { values = try await probe.properties() } catch { await probe.close(); throw error }
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
        guard !shuttingDown, !controlling else { return }
        await stopSync()
        guard !shuttingDown else { return }
        if let conn = connections.removeValue(forKey: entry.id) { await conn.close() }
        devices.removeAll { $0.id == entry.id }; config.assignments.removeValue(forKey: entry.id); save()
    }
    func run(_ entry: DeviceEntry, commands: [(String, [JSONValue])], duringScene: Bool = false) async {
        guard !shuttingDown, !scanning, (!transitioning || duringScene) else { return }
        let refresh = refreshTasks[entry.id]
        guard !entry.busy || refresh != nil else {
            error = "A command for \(entry.device.displayName) is still pending. Try again when it finishes."; return
        }
        if preview { notice = "Preview mode: commands stay on this Mac."; return }
        entry.busy = true; controlling = true
        let previous = controlTask
        let operationID = UUID()
        let operation = Task { [self] in
            await previous?.value
            await refresh?.value
            guard !shuttingDown, !Task.isCancelled else { return }
            entry.busy = true
            if active { await stopSync() } else { await cleanupTask?.value }
            guard !shuttingDown, !Task.isCancelled else { return }
            do {
                for cmd in commands {
                    guard !shuttingDown, !Task.isCancelled else { return }
                    _ = try await connection(entry).request(method: cmd.0, params: cmd.1)
                }
                guard !shuttingDown, !Task.isCancelled else { return }
                entry.error = nil; entry.online = true
                let values = try await connection(entry).properties()
                guard !shuttingDown, !Task.isCancelled else { return }
                entry.device.properties.merge(values) { _, new in new }; save()
            } catch {
                if !shuttingDown && !(error is CancellationError) {
                    entry.error = error.localizedDescription
                    self.error = "\(entry.device.displayName): \(error.localizedDescription)"
                }
            }
        }
        controls[operationID] = operation; controlTask = operation
        await operation.value
        controls.removeValue(forKey: operationID); controlling = !controls.isEmpty; entry.busy = false
        if controls.isEmpty { controlTask = nil }
    }
    func apply(_ scene: ScenePreset) async {
        guard !transitioning, !controlling, !scanning, !shuttingDown else { return }
        transitioning = true; defer { transitioning = false }
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
            return SavedLightState(deviceID: a.deviceID, channel: a.channel, properties: entry.device.properties)
        }
        config.savedScenes.append(SavedScene(name: String(trimmed.prefix(80)), actions: actions)); save()
    }
    func applySaved(_ scene: SavedScene) async {
        guard !transitioning, !controlling, !scanning, !shuttingDown else { return }
        transitioning = true; defer { transitioning = false }
        await stopSync()
        for state in scene.actions { guard !shuttingDown else { return }; if let entry = devices.first(where: { $0.id == state.deviceID }) { await run(entry, commands: restoreCommands(state), duringScene: true) } }
    }
    func loadDisplays() async {
        do {
            displays = try await screen.availableDisplays()
            if !displays.contains(where: { $0.id == config.displayID }) { config.displayID = displays.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    func start(_ target: SyncMode) async {
        guard !transitioning, !controlling, !scanning, !preview, !shuttingDown else { if preview { notice = "Connect a real light to start live sync." }; return }
        transitioning = true; defer { transitioning = false }
        await stopSync()
        error = nil
        let assignments = outputs
        guard !assignments.isEmpty else { error = "Add a light and enable it in Sync routing first."; return }
        generation += 1; let ticket = generation
        do {
            if target == .screen && displays.isEmpty { await loadDisplays() }
            try ensureCurrent(ticket)
            if target == .screen && config.displayID == nil { throw StationError.unavailable("Choose a display before starting Color Play.") }
            for a in assignments {
                guard let e = devices.first(where: { $0.id == a.deviceID }) else { continue }
                let current = try await connection(e).properties()
                try ensureCurrent(ticket)
                e.device.properties.merge(current) { _, new in new }
                restoreStates.append(SavedLightState(deviceID: a.deviceID, channel: a.channel, properties: current))
                activeAssignments.append(a)
                try await connection(e).startRealtime(channel: a.channel)
                try ensureCurrent(ticket)
            }
            if target == .screen, let display = config.displayID {
                try await screen.start(displayID: display, zones: layout.zones, interval: config.frameInterval) { [weak self] colors in
                    guard let self, self.generation == ticket else { return }; self.colors = colors; self.queueColors(colors)
                }
            } else {
                try await audio.start(source: audioSource) { [weak self] level in
                    guard let self, self.generation == ticket else { return }; self.receiveAudio(level)
                }
            }
            try ensureCurrent(ticket)
            for a in assignments {
                if let e = devices.first(where: { $0.id == a.deviceID }) {
                    let c = LightCommands.power(true, channel: a.channel)
                    _ = try await connection(e).request(method: c.0, params: c.1)
                    try ensureCurrent(ticket)
                }
            }
            guard target == .screen ? screen.isRunning : audio.isRunning else {
                throw StationError.unavailable(screen.lastError ?? audio.lastError ?? "Capture stopped before it became ready.")
            }
            mode = target; save()
        } catch { await stopSync(); if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    private func ensureCurrent(_ ticket: Int) throws {
        guard generation == ticket, !shuttingDown, !Task.isCancelled else { throw CancellationError() }
    }
    func stopSync() async {
        generation += 1; mode = .idle; pendingColors = nil
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
                    } catch { self.error = "Stopped sync; couldn’t restore \(entry.device.displayName): \(error.localizedDescription)" }
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
        shuttingDown = true; pollTask?.cancel()
        for operation in controls.values { operation.cancel() }
        for operation in refreshTasks.values { operation.cancel() }
        await pollTask?.value
        for operation in Array(refreshTasks.values) { await operation.value }
        for operation in Array(controls.values) { await operation.value }
        await stopSync()
        for connection in connections.values { await connection.close() }
    }
}
