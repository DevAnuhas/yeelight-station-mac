import AppKit
import AVFoundation
import ServiceManagement
import StationCapture
import StationCore
import SwiftUI

struct ColorPlayView: View {
    @EnvironmentObject private var model: StationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScreenZonePreview(layout: model.layout, colors: model.colors)
            HStack(alignment: .top, spacing: 18) {
                GroupBox("Capture") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Picker("Display", selection: Binding(get: { model.config.displayID ?? 0 }, set: { model.config.displayID = $0; model.save() })) {
                                if model.displays.isEmpty { Text("Choose a display…").tag(UInt32(0)) }
                                ForEach(model.displays) { display in Text("\(display.name) · \(display.width) × \(display.height)").tag(display.id) }
                            }
                            Button { Task { await model.loadDisplays() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Load displays")
                        }
                        Picker("Layout", selection: $model.config.layoutID) { ForEach(model.presets.layouts) { Text($0.name).tag($0.id) } }
                        Picker("Response", selection: $model.config.frameInterval) { Text("Slow · 450 ms").tag(0.45); Text("Normal · 200 ms").tag(0.2); Text("Fast · 100 ms").tag(0.1) }
                        Text("macOS may ask for screen access when you start. Screen colors are processed on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }.disabled(model.active || model.transitioning)
                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 16) {
                        brightness
                        Toggle("Restore color, brightness & power", isOn: $model.config.restoreOnStop).onChange(of: model.config.restoreOnStop) { _, _ in model.save() }
                        startButton(.screen)
                    }.padding(12)
                }.frame(width: 260)
            }
            SyncRoutingView()
        }.onChange(of: model.config.layoutID) { _, _ in model.save() }.onChange(of: model.config.frameInterval) { _, _ in model.save() }
    }
    private var brightness: some View { VStack { HStack { Text("Brightness"); Spacer(); Text("\(Int(model.config.syncBrightness))%").foregroundStyle(.secondary).monospacedDigit() }; Slider(value: $model.config.syncBrightness, in: 1...100, step: 1, onEditingChanged: { if !$0 { model.save() } }) } }
    @ViewBuilder private func startButton(_ mode: SyncMode) -> some View {
        Button {
            Task { if model.mode == mode { await model.stopSync() } else { await model.start(mode) } }
        } label: { Label(model.mode == mode ? "Stop Color Play" : "Start Color Play", systemImage: model.mode == mode ? "stop.fill" : "play.fill").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.transitioning || model.controlling)
    }
}

struct ScreenZonePreview: View {
    let layout: ScreenLayout
    let colors: [StationCore.RGBColor]
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.5))
                    ForEach(Array(layout.zones.enumerated()), id: \.offset) { index, zone in
                        let color = index < colors.count ? colors[index].color : Color(hue: Double(index) / Double(max(1, layout.zones.count)), saturation: 0.5, brightness: 0.6)
                        ZStack {
                            Rectangle().fill(color.opacity(0.5))
                            Rectangle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                            Text("\(index + 1)").font(.system(size: 18, weight: .medium, design: .rounded)).padding(9).background(.black.opacity(0.25), in: Circle())
                        }.frame(width: proxy.size.width * zone.width, height: proxy.size.height * zone.height)
                            .offset(x: proxy.size.width * zone.x, y: proxy.size.height * zone.y)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 9))
            }.frame(width: 420, height: 236).padding(9).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
            Capsule().fill(.white.opacity(0.2)).frame(width: 88, height: 5)
            Text("\(layout.name) · \(layout.zones.count) sampling zones").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(layout.name), \(layout.zones.count) color sampling zones")
    }
}

struct MusicFlowView: View {
    @EnvironmentObject private var model: StationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 20) {
                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(0..<25) { i in
                        let f = Double(i % 7 + 1) / 7
                        let color = StationCore.RGBColor(packed: model.palette.colors[i % model.palette.colors.count]).color
                        Capsule().fill(color).frame(width: 10, height: max(7, model.audioLevel * (45 + f * 105)))
                    }
                }.frame(height: 155, alignment: .bottom)
                Text(model.mode == .music ? "Listening to \(model.audioSource == .system ? "system audio" : "your microphone")" : "Start Music Flow to see your audio level").font(.callout).foregroundStyle(.secondary)
            }.padding(30).frame(maxWidth: .infinity).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            HStack(alignment: .top, spacing: 18) {
                GroupBox("Sound & color") {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Audio source", selection: $model.audioSource) { Text("System audio").tag(AudioSource.system); Text("Microphone").tag(AudioSource.microphone) }.disabled(model.active || model.transitioning)
                        Picker("Palette", selection: $model.config.paletteID) {
                            ForEach(model.presets.palettes) { Text("\($0.group) / \($0.name)").tag($0.id) }
                        }
                        HStack(spacing: 4) { ForEach(Array(model.palette.colors.enumerated()), id: \.offset) { _, rgb in RoundedRectangle(cornerRadius: 4).fill(StationCore.RGBColor(packed: rgb).color).frame(height: 20) } }.accessibilityLabel("Palette colors")
                        VStack { HStack { Text("Sensitivity"); Spacer(); Text(String(format: "%.1f×", model.config.sensitivity)).foregroundStyle(.secondary) }; Slider(value: $model.config.sensitivity, in: 0.25...8, onEditingChanged: { if !$0 { model.save() } }) }
                    }.padding(12)
                }
                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack { HStack { Text("Brightness"); Spacer(); Text("\(Int(model.config.syncBrightness))%").foregroundStyle(.secondary) }; Slider(value: $model.config.syncBrightness, in: 1...100, step: 1, onEditingChanged: { if !$0 { model.save() } }) }
                        Toggle("Restore color, brightness & power", isOn: $model.config.restoreOnStop).onChange(of: model.config.restoreOnStop) { _, _ in model.save() }
                        Button { Task { if model.mode == .music { await model.stopSync() } else { await model.start(.music) } } } label: { Label(model.mode == .music ? "Stop Music Flow" : "Start Music Flow", systemImage: model.mode == .music ? "stop.fill" : "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.transitioning || model.controlling)
                        Text("Only the selected audio source is used. Sound is processed on this Mac and is never saved.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }.frame(width: 260)
            }
            SyncRoutingView()
        }.onChange(of: model.config.paletteID) { _, _ in model.save() }
    }
}

struct SyncRoutingView: View {
    @EnvironmentObject private var model: StationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync routing").font(.title3.weight(.semibold))
            Text("Choose the lights and screen zones to use. Task lights stay independent from RGB backlights.").font(.callout).foregroundStyle(.secondary)
            if model.devices.isEmpty { EmptyLightsView() } else {
                VStack(spacing: 15) { ForEach(model.devices) { entry in RoutingRow(entry: entry) } }.padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }.disabled(model.active || model.transitioning)
    }
}

private struct RoutingRow: View {
    @EnvironmentObject private var model: StationModel
    @ObservedObject var entry: DeviceEntry
    var body: some View {
        HStack(spacing: 16) {
            Toggle(entry.device.displayName, isOn: Binding(get: { model.assignment(for: entry).enabled }, set: { value in model.updateAssignment(entry) { $0.enabled = value } })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
            if entry.device.hasBackground {
                Picker("Channel", selection: Binding(get: { model.assignment(for: entry).channel }, set: { value in model.updateAssignment(entry) { $0.channel = value } })) { Text("RGB backlight").tag(LightChannel.background); Text("Task light").tag(LightChannel.main) }.labelsHidden().frame(width: 155)
            }
            Picker("Zone", selection: Binding(get: { min(model.layout.zones.count - 1, model.assignment(for: entry).zone) }, set: { value in model.updateAssignment(entry) { $0.zone = value } })) {
                ForEach(0..<model.layout.zones.count, id: \.self) { Text("Zone \($0 + 1)").tag($0) }
            }.frame(width: 130)
        }
    }
}

struct ScenesView: View {
    @EnvironmentObject private var model: StationModel
    @State private var showSave = false
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Station presets").font(.title3.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) { ForEach(model.presets.scenes) { SceneTile(scene: $0) } }
            Text("Scenes apply to lights enabled in Sync routing. White scenes are translated to RGB on color-only backlights.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Text("My scenes").font(.title3.weight(.semibold)); Spacer(); Button("Save current lights", systemImage: "plus") { name = ""; showSave = true }.disabled(model.devices.isEmpty || model.active) }
            if model.config.savedScenes.isEmpty { Text("Set your lights how you like them, then save the selected channels as a scene.").font(.callout).foregroundStyle(.secondary) }
            ForEach(model.config.savedScenes) { scene in
                HStack {
                    Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 4) { Text(scene.name); Text("\(scene.actions.count) light channels").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Apply") { Task { await model.applySaved(scene) } }
                    Button(role: .destructive) { model.config.savedScenes.removeAll { $0.id == scene.id }; model.save() } label: { Image(systemName: "trash") }.accessibilityLabel("Delete \(scene.name)")
                }.padding(15).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
            SyncRoutingView()
        }.alert("Save current lights", isPresented: $showSave) {
            TextField("Scene name", text: $name)
            Button("Save") { model.saveScene(name: name) }; Button("Cancel", role: .cancel) {}
        } message: { Text("Saves the current state of the channels enabled in Sync routing.") }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: StationModel
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var screenAllowed = false
    @State private var microphoneStatus = AVAuthorizationStatus.notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupBox("Everyday use") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Start in the menu bar at login", isOn: Binding(
                        get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                        set: setLoginEnabled
                    )).disabled(model.preview)
                    if loginStatus == .requiresApproval {
                        HStack {
                            Text("Allow Station in Login Items to finish setup.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    Toggle("Restore lights when sync stops", isOn: $model.config.restoreOnStop)
                        .onChange(of: model.config.restoreOnStop) { _, _ in model.save() }
                    Text("Close the window to keep Station running. Click or right-click its menu bar icon for light controls, scenes, and Stop Sync. Choose Quit to stop Station.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Light controls need Local Network access. Screen and microphone access are optional, and requested only when you start a feature that uses them.")
                        .font(.callout).foregroundStyle(.secondary)
                    permissionRow("Local Network", symbol: "network", detail: "Connect to your lights on the same Wi-Fi or LAN.", status: nil, ready: false, anchor: "Privacy_LocalNetwork")
                    Divider()
                    permissionRow("Screen & system audio", symbol: "display", detail: "Used by Color Play and Music Flow with system audio.", status: screenAllowed ? "Allowed" : "Not enabled", ready: screenAllowed, anchor: "Privacy_ScreenCapture")
                    Divider()
                    permissionRow("Microphone", symbol: "mic", detail: "Only needed when you choose microphone input.", status: microphoneLabel, ready: microphoneStatus == .authorized, anchor: "Privacy_Microphone")
                    Text("Changing these settings doesn’t start capture. macOS may ask you to reopen Station after granting access.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Connection help") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enable LAN Control in the Yeelight phone app. Keep your Mac and light on the same network. You can also add a light by its IP address.")
                    Text("If you use Little Snitch or another network filter, allow this installed copy of Station to connect to your lights.")
                    Button("Reveal settings file", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore().url]) }
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            }
            DisclosureGroup("About Station") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Yeelight Station for Mac · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                    Text("Independent macOS app. Monitor Light Bar Pro task light and RGB backlight are controlled separately. Razer Chroma and Overwolf integrations are not available.").foregroundStyle(.secondary)
                }.font(.callout).padding(.top, 10)
            }
        }
        .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        .onAppear(perform: refreshAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshAccess() }
    }

    private var microphoneLabel: String {
        switch microphoneStatus {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not requested"
        case .denied, .restricted: return "Not enabled"
        @unknown default: return "Check Settings"
        }
    }
    private func permissionRow(_ title: String, symbol: String, detail: String, status: String?, ready: Bool, anchor: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).fontWeight(.medium)
                    if let status { Text(status).font(.caption).foregroundStyle(ready ? Color.green : Color.secondary) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Settings…") { openSettings(anchor) }.controlSize(.small).accessibilityLabel("Open \(title) settings")
        }
    }
    private func refreshAccess() {
        // Read-only checks; displaying Settings never requests permission or starts capture.
        loginStatus = SMAppService.mainApp.status
        guard !model.preview else { return }
        screenAllowed = CGPreflightScreenCaptureAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    private func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = "Couldn’t update login startup. \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

private struct FullWidthDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))

            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }
}
