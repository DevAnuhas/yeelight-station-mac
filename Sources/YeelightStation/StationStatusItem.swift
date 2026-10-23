import AppKit
import Combine
import StationCapture
import StationCore

enum StationMenuAction: Equatable {
    case openStation, settings, quit
    case power(deviceID: String, channel: LightChannel, on: Bool)
    case brightness(deviceID: String, channel: LightChannel, percent: Int)
    case start(SyncMode, displayID: UInt32? = nil, audioSource: AudioSource? = nil, inputDeviceUID: String? = nil), stop, savedScene(UUID)

    struct StartRequest: Equatable {
        let mode: SyncMode
        let displayID: UInt32?
        var audioSource: AudioSource? = nil
        var inputDeviceUID: String? = nil
    }

    // Menu items are snapshots. Resolve their intent against current state before
    // changing the shared selection or starting any capture/device operation.
    func startRequest(in state: StationMenuState, isTerminating: Bool = false) -> StartRequest? {
        guard !isTerminating, case .start(let mode, let displayID, let source, let inputDeviceUID) = self else { return nil }
        if mode == .screen {
            guard source == nil, inputDeviceUID == nil, state.allowsStart(mode, displayID: displayID) else { return nil }
            return StartRequest(mode: mode, displayID: displayID ?? state.selectedDisplayID)
        }
        guard mode == .music, displayID == nil,
              inputDeviceUID == nil || source == .microphone else { return nil }
        let candidateSource = source ?? state.audioSource
        let candidateUID = candidateSource == .microphone ? (source == nil ? state.selectedAudioInputUID : inputDeviceUID) : nil
        guard state.allowsStart(mode, audioSource: candidateSource, inputDeviceUID: candidateUID) else { return nil }
        return StartRequest(mode: mode, displayID: nil, audioSource: candidateSource, inputDeviceUID: candidateUID)
    }

    @MainActor
    func prepareStart(on model: StationModel, isTerminating: Bool = false) -> SyncMode? {
        guard let request = startRequest(in: StationMenuState(model: model), isTerminating: isTerminating) else { return nil }
        if let source = request.audioSource {
            guard model.canStart(request.mode, displayID: nil, audioSource: source, inputDeviceUID: request.inputDeviceUID) else { return nil }
            if source == .microphone, !model.selectAudioInput(uid: request.inputDeviceUID) { return nil }
            model.audioSource = source
            return model.canStart(request.mode) ? request.mode : nil
        }
        guard model.canStart(request.mode, displayID: request.displayID) else { return nil }
        if let displayID = request.displayID, !model.selectDisplay(displayID) { return nil }
        return model.canStart(request.mode) ? request.mode : nil
    }

    // Resolve again on selection: discovery may change devices while a menu is open.
    func deviceCommand(in devices: [LightDevice]) -> (deviceID: String, command: (String, [JSONValue]))? {
        let id: String, channel: LightChannel, command: (String, [JSONValue])
        switch self {
        case .power(let deviceID, let selectedChannel, let on):
            id = deviceID; channel = selectedChannel; command = LightCommands.power(on, channel: channel)
        case .brightness(let deviceID, let selectedChannel, let percent):
            guard StationMenuState.brightnessPresets.contains(percent) else { return nil }
            id = deviceID; channel = selectedChannel; command = LightCommands.brightness(percent, channel: channel)
        default: return nil
        }
        guard let device = devices.first(where: { $0.id == id }), channel == .main || device.hasBackground else { return nil }
        return (id, command)
    }

    @MainActor
    func executeDeviceCommand(on model: StationModel) async {
        guard StationMenuState(model: model).allowsControl,
              let resolved = deviceCommand(in: model.devices.map(\.device)),
              let entry = model.devices.first(where: { $0.id == resolved.deviceID }) else { return }
        if case .brightness(_, let channel, let percent) = self {
            model.setBrightness(entry, channel: channel, value: percent)
        } else {
            // Power remains a serialized command that waits for polling.
            await model.run(entry, commands: [resolved.command])
        }
    }
}

struct StationMenuState {
    static let brightnessPresets = [25, 50, 75, 100]
    struct Device {
        let light: LightDevice
        let online: Bool
        let busy: Bool
        let error: String?

        var channels: [LightChannel] { light.hasBackground ? [.main, .background] : [.main] }
        func power(_ channel: LightChannel) -> Bool? {
            switch light.properties[channel == .background ? "bg_power" : "power"] {
            case "on": return true
            case "off": return false
            default: return nil
            }
        }
        func selectedBrightness(_ channel: LightChannel) -> Int? {
            guard let value = light.properties[channel == .background ? "bg_bright" : "bright"].flatMap(Int.init),
                  StationMenuState.brightnessPresets.contains(value) else { return nil }
            return value
        }
        func powerAction(_ channel: LightChannel) -> StationMenuAction {
            .power(deviceID: light.id, channel: channel, on: power(channel) != true)
        }
    }
    let devices: [Device]
    let mode: SyncMode
    let transitioning: Bool
    let controlling: Bool
    let scanning: Bool
    let preview: Bool
    let hasOutputs: Bool
    let error: String?
    let displays: [CaptureDisplay]
    let selectedDisplayID: UInt32?
    let audioSource: AudioSource
    let audioInputs: [AudioInputDevice]
    let selectedAudioInputUID: String?
    let shuttingDown: Bool

    var allowsControl: Bool { !preview && !transitioning && !controlling && !scanning && !shuttingDown }
    var selectedAudioInput: AudioInputDevice? {
        if let selectedAudioInputUID { return audioInputs.first { $0.id == selectedAudioInputUID } }
        return audioInputs.first(where: \.isDefault)
    }
    func requiresDisplay(for target: SyncMode) -> Bool { target == .screen }
    func allowsStart(_ target: SyncMode, displayID: UInt32? = nil, audioSource candidateSource: AudioSource? = nil,
                     inputDeviceUID: String? = nil) -> Bool {
        guard allowsControl && hasOutputs && target != .idle && mode != target else { return false }
        if target == .screen { return displays.contains { $0.id == (displayID ?? selectedDisplayID) } }
        guard displayID == nil else { return false }
        if (candidateSource ?? audioSource) == .system { return !displays.isEmpty }
        let uid = candidateSource == nil ? selectedAudioInputUID : inputDeviceUID
        if let uid { return audioInputs.contains { $0.id == uid } }
        return audioInputs.contains(where: \.isDefault)
    }
    var allowsStop: Bool { mode != .idle || transitioning }
    var status: String {
        if preview { return "Preview mode · No device commands" }
        if transitioning { return "Changing sync…" }
        if controlling { return "Updating lights…" }
        if scanning { return "Discovering lights…" }
        switch mode {
        case .idle: return "Sync is stopped"
        case .screen: return "Color Play is running"
        case .music: return "Music Flow is running"
        }
    }
    var connectionStatus: String {
        if devices.isEmpty { return "No lights added" }
        return "\(devices.filter(\.online).count) of \(devices.count) lights online"
    }
    var tooltip: String {
        var lines = ["Yeelight Station", status, connectionStatus]
        if let error, !error.isEmpty { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    @MainActor init(model: StationModel) {
        devices = model.devices.map { Device(light: $0.device, online: $0.online, busy: $0.busy, error: $0.error) }
        mode = model.mode; transitioning = model.transitioning; controlling = model.controlling
        scanning = model.scanning; preview = model.preview; hasOutputs = !model.outputs.isEmpty; error = model.error
        displays = model.displays; selectedDisplayID = model.selectedDisplay?.id; audioSource = model.audioSource
        audioInputs = model.audioInputs; selectedAudioInputUID = model.selectedAudioInputUID
        shuttingDown = model.isShuttingDown
    }

    init(devices: [Device], mode: SyncMode = .idle, transitioning: Bool = false, controlling: Bool = false,
         scanning: Bool = false, preview: Bool = false, hasOutputs: Bool = true, error: String? = nil,
         displays: [CaptureDisplay] = [], selectedDisplayID: UInt32? = nil, audioSource: AudioSource = .system,
         audioInputs: [AudioInputDevice] = [], selectedAudioInputUID: String? = nil,
         shuttingDown: Bool = false) {
        self.devices = devices; self.mode = mode; self.transitioning = transitioning; self.controlling = controlling
        self.scanning = scanning; self.preview = preview; self.hasOutputs = hasOutputs; self.error = error
        self.displays = displays; self.selectedDisplayID = selectedDisplayID; self.audioSource = audioSource
        self.audioInputs = audioInputs; self.selectedAudioInputUID = selectedAudioInputUID
        self.shuttingDown = shuttingDown
    }
}

@MainActor
enum StationSyncMenu {
    static func startItem(_ mode: SyncMode, state: StationMenuState, target: AnyObject? = nil,
                          selector: Selector? = nil, isTerminating: Bool = false) -> NSMenuItem {
        let title = mode == .screen ? "Start Color Play" : "Start Music Flow"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.state = state.mode == mode ? .on : .off
        if mode == .music {
            let submenu = NSMenu(title: title); submenu.autoenablesItems = false
            let system = actionItem("System Audio", mode: mode, audioSource: .system, state: state,
                                    target: target, selector: selector, isTerminating: isTerminating)
            system.state = state.audioSource == .system ? .on : .off
            submenu.addItem(system)
            for input in state.audioInputs {
                let choice = actionItem(input.name, mode: mode, audioSource: .microphone, inputDeviceUID: input.id,
                                        state: state, target: target, selector: selector, isTerminating: isTerminating)
                choice.state = state.audioSource == .microphone && state.selectedAudioInput?.id == input.id ? .on : .off
                submenu.addItem(choice)
            }
            if state.audioInputs.isEmpty {
                let unavailable = NSMenuItem(title: "No audio input devices available", action: nil, keyEquivalent: "")
                unavailable.isEnabled = false; submenu.addItem(unavailable)
            }
            item.submenu = submenu
            item.isEnabled = submenu.items.contains(where: \.isEnabled)
        } else if state.requiresDisplay(for: mode), state.displays.count > 1 {
            let submenu = NSMenu(title: title); submenu.autoenablesItems = false
            for display in state.displays {
                let choice = actionItem("\(display.name) · \(display.width) × \(display.height)", mode: mode,
                                        displayID: display.id, state: state, target: target, selector: selector,
                                        isTerminating: isTerminating)
                choice.state = state.selectedDisplayID == display.id ? .on : .off
                submenu.addItem(choice)
            }
            item.submenu = submenu
            item.isEnabled = submenu.items.contains(where: \.isEnabled)
        } else {
            let displayID = state.requiresDisplay(for: mode) ? state.displays.first?.id : nil
            let action = actionItem(title, mode: mode, displayID: displayID, state: state, target: target,
                                    selector: selector, isTerminating: isTerminating)
            action.state = item.state
            return action
        }
        return item
    }

    private static func actionItem(_ title: String, mode: SyncMode, displayID: UInt32? = nil,
                                   audioSource: AudioSource? = nil, inputDeviceUID: String? = nil, state: StationMenuState,
                                   target: AnyObject?, selector: Selector?, isTerminating: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        let action = StationMenuAction.start(mode, displayID: displayID, audioSource: audioSource, inputDeviceUID: inputDeviceUID)
        item.target = target; item.representedObject = action
        item.isEnabled = action.startRequest(in: state, isTerminating: isTerminating) != nil
        return item
    }
}

@MainActor
final class StationStatusItem: NSObject {
    private let model: StationModel
    private let item: NSStatusItem
    private let openStation: () -> Void
    private let openSettings: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var deviceSubscriptions = Set<AnyCancellable>()
    private var updateTask: Task<Void, Never>?
    var isTerminating = false { didSet { updatePresentation() } }

    init(model: StationModel, openStation: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model; self.openStation = openStation; self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.target = self; button.action = #selector(showMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Yeelight Station")
        }
        model.$devices.sink { [weak self] entries in
            self?.observeDevices(entries); self?.scheduleUpdate()
        }.store(in: &subscriptions)
        Publishers.MergeMany([
            model.$mode.map { _ in () }.eraseToAnyPublisher(),
            model.$transitioning.map { _ in () }.eraseToAnyPublisher(),
            model.$controlling.map { _ in () }.eraseToAnyPublisher(),
            model.$scanning.map { _ in () }.eraseToAnyPublisher(),
            model.$config.map { _ in () }.eraseToAnyPublisher(),
            model.$displays.map { _ in () }.eraseToAnyPublisher(),
            model.$audioSource.map { _ in () }.eraseToAnyPublisher(),
            model.$audioInputs.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedAudioInputUID.map { _ in () }.eraseToAnyPublisher(),
            model.$error.map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
        updatePresentation()
    }

    private func observeDevices(_ entries: [DeviceEntry]) {
        deviceSubscriptions.removeAll()
        for entry in entries {
            entry.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &deviceSubscriptions)
        }
    }

    private func scheduleUpdate() {
        guard updateTask == nil else { return }
        // Published values notify before assignment; coalesce and read them on
        // the next MainActor turn. Never observe per-frame capture colors.
        updateTask = Task { [weak self] in
            guard let self else { return }
            self.updateTask = nil; self.updatePresentation()
        }
    }

    private func updatePresentation() {
        let state = StationMenuState(model: model)
        let image = NSImage(systemSymbolName: model.active ? "lightbulb.fill" : "lightbulb", accessibilityDescription: "Yeelight Station")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = isTerminating ? "Yeelight Station · Quitting…" : state.tooltip
        item.button?.setAccessibilityValue(state.status + ". " + state.connectionStatus)
    }

    @objc private func showMenu() {
        guard let button = item.button else { return }
        // Build from current model/device values for either mouse button.
        let menu = makeMenu()
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        button.highlight(false)
    }

    private func makeMenu() -> NSMenu {
        let state = StationMenuState(model: model)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(isTerminating ? "Quitting…" : state.status))
        menu.addItem(menuItem(state.connectionStatus))
        if let error = state.error, !error.isEmpty {
            let errorItem = menuItem("Error: " + concise(error), action: .openStation)
            errorItem.toolTip = error; menu.addItem(errorItem)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Station", action: .openStation, key: "o"))
        if !state.devices.isEmpty { menu.addItem(.separator()) }
        for device in state.devices {
            let title = concise(device.light.displayName) + (device.online ? "" : " · Offline")
            let parent = menuItem(title)
            let controls = NSMenu(title: device.light.displayName); controls.autoenablesItems = false
            if let error = device.error, !error.isEmpty {
                let errorItem = menuItem(concise(error), action: .openStation)
                errorItem.toolTip = error; controls.addItem(errorItem); controls.addItem(.separator())
            }
            for channel in device.channels {
                if channel == .background { controls.addItem(.separator()) }
                let power = device.power(channel)
                let label = device.light.hasBackground ? channel.title : "Light"
                let powerItem = menuItem(label + (power == nil ? " (power unknown)" : ""),
                                         action: device.powerAction(channel), enabled: state.allowsControl)
                powerItem.state = power.map { $0 ? .on : .off } ?? .mixed
                powerItem.toolTip = "Turn \(label.lowercased()) \(power == true ? "off" : "on")"
                controls.addItem(powerItem)
                let brightness = menuItem(label + " brightness")
                let presets = NSMenu(title: label + " brightness"); presets.autoenablesItems = false
                for percent in StationMenuState.brightnessPresets {
                    let preset = menuItem("\(percent)%", action: .brightness(deviceID: device.light.id, channel: channel, percent: percent),
                                          enabled: state.allowsControl)
                    preset.state = device.selectedBrightness(channel) == percent ? .on : .off
                    presets.addItem(preset)
                }
                brightness.submenu = presets; brightness.isEnabled = !isTerminating
                controls.addItem(brightness)
            }
            parent.submenu = controls; parent.isEnabled = !isTerminating; menu.addItem(parent)
        }
        menu.addItem(.separator())
        for mode in [SyncMode.screen, .music] {
            menu.addItem(StationSyncMenu.startItem(mode, state: state, target: self,
                                                  selector: #selector(performAction(_:)), isTerminating: isTerminating))
        }
        menu.addItem(menuItem("Stop Sync", action: .stop, enabled: state.allowsStop))
        if !model.config.savedScenes.isEmpty {
            let scenes = menuItem("Saved scenes")
            let presets = NSMenu(title: "Saved scenes"); presets.autoenablesItems = false
            // Keep quick access short; the full library remains in Station.
            for scene in model.config.savedScenes.prefix(10) {
                presets.addItem(menuItem(concise(scene.name), action: .savedScene(scene.id),
                                         enabled: state.allowsControl && !scene.actions.isEmpty))
            }
            if model.config.savedScenes.count > 10 {
                presets.addItem(.separator()); presets.addItem(menuItem("All scenes in Station…", action: .openStation))
            }
            scenes.submenu = presets; scenes.isEnabled = !isTerminating; menu.addItem(scenes)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", action: .settings, key: ","))
        menu.addItem(menuItem("Quit Yeelight Station", action: .quit, key: "q"))
        return menu
    }

    private func concise(_ value: String) -> String {
        let line = value.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 76 ? String(line.prefix(75)) + "…" : line
    }

    private func menuItem(_ title: String, action: StationMenuAction? = nil, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(performAction(_:)), keyEquivalent: key)
        item.target = self; item.representedObject = action
        item.isEnabled = action != nil && enabled && !isTerminating
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard !isTerminating, let action = sender.representedObject as? StationMenuAction else { return }
        switch action {
        case .openStation: openStation()
        case .settings: openSettings()
        case .quit: NSApp.terminate(nil)
        default: Task { await perform(action) }
        }
    }

    private func perform(_ action: StationMenuAction) async {
        guard !isTerminating else { return }
        let state = StationMenuState(model: model)
        switch action {
        case .power, .brightness:
            await action.executeDeviceCommand(on: model)
        case .start:
            guard let mode = action.prepareStart(on: model, isTerminating: isTerminating) else { return }
            await model.start(mode)
        case .stop:
            guard state.allowsStop else { return }; await model.stopSync()
        case .savedScene(let id):
            guard state.allowsControl, let scene = model.config.savedScenes.first(where: { $0.id == id }) else { return }
            await model.applySaved(scene)
        default: break
        }
    }
}
