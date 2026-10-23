import AppKit
import StationCapture
import StationCore
import SwiftUI

private let stationAccent = StationAppearance.accent

extension StationCore.RGBColor {
    var color: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }
}

enum StationPage: String, CaseIterable, Identifiable {
    case station = "Station", lights = "My Lights", screen = "Color Play", music = "Music Flow", scenes = "Scenes", automations = "Automations", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self { case .station: return "square.grid.2x2"; case .lights: return "lightbulb.2"; case .screen: return "display"; case .music: return "waveform"; case .scenes: return "sparkles"; case .automations: return "clock.arrow.circlepath"; case .settings: return "gearshape" }
    }
    var subtitle: String {
        switch self {
        case .station: return "Your desk. Your atmosphere."
        case .lights: return "Local control, with separate task-light and backlight channels."
        case .screen: return "Bring the colors on your screen into your room."
        case .music: return "Let your lights follow the sound."
        case .scenes: return "A different atmosphere, one click away."
        case .automations: return "A daily rhythm for each light."
        case .settings: return "Make Station fit your day."
        }
    }
}

struct StationView: View {
    @EnvironmentObject private var model: StationModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: StationPage? = .station
    @State private var showAdd = false

    init(initialPage: StationPage = .station) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                Image(nsImage: StationBrand.image(for: colorScheme))
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 160, height: 36)
                    .accessibilityLabel("Yeelight")
                    .padding(.horizontal, 16).padding(.top, 10)
                List(selection: $page) {
                    Section("WORKSPACE") {
                        Label(StationPage.station.rawValue, systemImage: StationPage.station.symbol).tag(StationPage.station)
                        HStack { Label("My Lights", systemImage: "lightbulb.2"); Spacer(); Text("\(model.devices.count)").foregroundStyle(.secondary) }.tag(StationPage.lights)
                        Label(StationPage.automations.rawValue, systemImage: StationPage.automations.symbol).tag(StationPage.automations)
                    }
                    Section("SYNC & SCENES") {
                        ForEach([StationPage.screen, .music, .scenes]) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                    }
                    Section { Label("Settings", systemImage: "gearshape").tag(StationPage.settings) }
                }.listStyle(.sidebar)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 7) {
                    Label(model.active ? "Sync is running" : "Ready when you are", systemImage: model.active ? "circle.fill" : "circle")
                        .font(.caption).foregroundStyle(model.active ? .green : .secondary)
                    Text("\(model.onlineCount) / \(model.devices.count) lights online").font(.caption2).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if model.preview {
                    HStack { Image(systemName: "eye"); Text("PREVIEW MODE").fontWeight(.semibold); Text("No device commands are sent."); Spacer() }
                        .font(.caption).padding(.horizontal, 26).padding(.vertical, 9).background(stationAccent.opacity(0.16))
                }
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text((page ?? .station).rawValue).font(.system(size: 29, weight: .semibold, design: .rounded))
                        Text((page ?? .station).subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.active { Button("Stop Sync", systemImage: "stop.fill") { Task { await model.stopSync() } }.tint(.orange) }
                    Button { showAdd = true } label: { Label("Add Light", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(stationAccent)
                }.padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 20)
                Divider().opacity(0.5)
                if let error = model.error {
                    MessageStrip(message: error, symbol: "exclamationmark.triangle", color: .orange) { model.error = nil }
                }
                if let notice = model.notice {
                    MessageStrip(message: notice, symbol: "info.circle", color: stationAccent) { model.notice = nil }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        switch page ?? .station {
                        case .station: dashboard
                        case .lights: LightLibraryView()
                        case .screen: ColorPlayView()
                        case .music: MusicFlowView()
                        case .scenes: ScenesView()
                        case .automations: AutomationsView()
                        case .settings: SettingsView()
                        }
                    }.padding(28).frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(StationAppearance.windowBackground)
        }
        .tint(stationAccent)
        .sheet(isPresented: $showAdd) { AddLightView().environmentObject(model) }
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 16) {
                FeatureCard(title: "Color Play", subtitle: "Your screen, beyond the screen.", symbol: "display", kind: .screen, active: model.mode == .screen) { page = .screen }
                FeatureCard(title: "Music Flow", subtitle: "Sound becomes color.", symbol: "waveform", kind: .music, active: model.mode == .music) { page = .music }
            }
            HStack { Text("Set the scene").font(.title3.weight(.semibold)); Spacer(); Button("All scenes", systemImage: "arrow.right") { page = .scenes }.buttonStyle(.plain).foregroundStyle(stationAccent) }
            HStack(spacing: 12) {
                ForEach(model.presets.scenes.filter { ["Gaming", "Movie", "Party", "Relax"].contains($0.name) }) { scene in SceneTile(scene: scene) }
            }
            HStack { Text("My lights").font(.title3.weight(.semibold)); Spacer(); if !model.devices.isEmpty { Button("Manage lights") { page = .lights }.buttonStyle(.plain).foregroundStyle(stationAccent) } }
            if model.devices.isEmpty { EmptyLightsView() } else { ForEach(model.devices) { entry in DeviceCard(entry: entry) } }
        }
    }
}

struct MessageStrip: View {
    let message: String, symbol: String
    let color: Color
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(14).background(color.opacity(0.1))
    }
}

struct FeatureCard: View {
    let title: String, subtitle: String, symbol: String
    let kind: SyncMode
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(colors: kind == .screen ? [.indigo.opacity(0.7), .purple.opacity(0.25), .cyan.opacity(0.15)] : [.pink.opacity(0.32), .orange.opacity(0.12), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if kind == .screen {
                        ZStack {
                            // The neck sits behind the display and meets the base;
                            // its top is hidden by the lower bezel, not the screen.
                            Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 12, height: 20).offset(y: 60)
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.3)).frame(width: 40, height: 4).offset(y: 70)
                            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.65)).frame(width: 172, height: 104)
                            RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [.cyan, .indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 158, height: 90)
                            Rectangle().fill(.white.opacity(0.45)).frame(width: 76, height: 4).offset(y: -56)
                        }.shadow(color: .purple.opacity(0.3), radius: 20)
                    } else {
                        HStack(alignment: .center, spacing: 7) {
                            ForEach(Array([22, 42, 72, 104, 62, 120, 86, 50, 94, 62, 34, 18].enumerated()), id: \.offset) { i, height in
                                Capsule().fill(LinearGradient(colors: [.pink.opacity(0.9), .orange.opacity(0.7), .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom)).frame(width: 9, height: CGFloat(height))
                            }
                        }
                    }
                    if active { Text("LIVE").font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(.green.opacity(0.25), in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(15) }
                }.frame(height: 185).clipped()
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: symbol).font(.title3.weight(.semibold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "arrow.up.right").font(.title3).foregroundStyle(.secondary)
                }.padding(20)
            }.background(StationAppearance.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StationAppearance.cardBorder))
        }.buttonStyle(.plain).accessibilityLabel("Configure \(title)")
    }
}

struct EmptyLightsView: View {
    @EnvironmentObject private var model: StationModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.led.wide").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(stationAccent)
            Text("Make room for your light").font(.title3.weight(.medium))
            Text("Enable LAN Control in the Yeelight app, then connect this Mac to the same Wi-Fi network.")
                .foregroundStyle(.secondary).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 400)
            Text("Use Add Light to discover devices or enter an IP address.").font(.caption).foregroundStyle(.secondary)
        }.padding(34).frame(maxWidth: .infinity).background(StationAppearance.subtleBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LightLibraryView: View {
    @EnvironmentObject private var model: StationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("\(model.onlineCount) of \(model.devices.count) online", systemImage: "network").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }.disabled(model.active)
            }
            if model.devices.isEmpty { EmptyLightsView() } else { ForEach(model.devices) { DeviceCard(entry: $0) } }
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject private var model: StationModel
    @ObservedObject var entry: DeviceEntry
    @State private var remove = false
    @State private var rename = false
    @State private var newName = ""
    @State private var settingsSection: DeviceSettingsSection?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: entry.device.hasBackground ? "lightbulb.led.wide.fill" : "lightbulb.fill").font(.title2).foregroundStyle(stationAccent).frame(width: 38)
                VStack(alignment: .leading, spacing: 4) { Text(entry.device.displayName).font(.headline); Text("\(entry.device.model) · \(entry.device.host)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                if entry.busy { ProgressView().controlSize(.small) }
                Label(entry.online ? "Online" : "Offline", systemImage: "circle.fill").font(.caption).foregroundStyle(entry.online ? .green : .secondary)
                Menu {
                    Button("Device settings…") { settingsSection = .information }
                    Button("Sleep timer…") { settingsSection = .timer }
                    Divider()
                    Button("Refresh connection") { Task { await model.refresh(entry) } }
                    Button("Rename locally") { newName = entry.device.displayName; rename = true }
                    Divider(); Button("Remove light", role: .destructive) { remove = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 25)
                    .accessibilityLabel("Options for \(entry.device.displayName)")
            }
            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack(alignment: .top, spacing: 22) {
                ChannelControl(entry: entry, channel: .main)
                if entry.device.hasBackground { Divider(); ChannelControl(entry: entry, channel: .background) }
            }.disabled(model.transitioning || model.controlling || model.scanning || model.isShuttingDown)
        }.padding(20).background(StationAppearance.cardBackground, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StationAppearance.cardBorder))
        .sheet(item: $settingsSection) { section in
            DeviceSettingsView(entry: entry, initialSection: section).environmentObject(model)
        }
        .confirmationDialog("Remove \(entry.device.displayName)?", isPresented: $remove) { Button("Remove Light", role: .destructive) { Task { await model.remove(entry) } } } message: { Text("This removes it from Station on this Mac.") }
        .alert("Rename light on this Mac", isPresented: $rename) {
            TextField("Name", text: $newName)
            Button("Save") { let value = newName.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { entry.device.name = String(value.prefix(80)); model.save() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ChannelControl: View {
    @EnvironmentObject private var model: StationModel
    @ObservedObject var entry: DeviceEntry
    let channel: LightChannel
    @State private var brightness = 50.0
    @State private var temperature = 4000.0
    @State private var editingBrightness = false
    @State private var editingTemperature = false
    var isColor: Bool { channel == .background || !entry.device.hasBackground }
    private var color: StationCore.RGBColor {
        StationCore.RGBColor(packed: Int(entry.value("rgb", channel: channel) ?? "16777215") ?? 16777215)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(entry.device.hasBackground ? channel.title : "Light").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Power", isOn: Binding(get: { entry.value("power", channel: channel) == "on" }, set: { value in send(LightCommands.power(value, channel: channel)) })).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("\(channel.title) power")
            }
            VStack(spacing: 7) {
                HStack { Label("Brightness", systemImage: "sun.max"); Spacer(); Text("\(Int(brightness))%").monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
                Slider(value: Binding(get: { brightness }, set: { value in
                    brightness = value
                    model.setBrightness(entry, channel: channel, value: Int(value))
                }), in: 1...100, step: 1, onEditingChanged: { editing in
                    editingBrightness = editing
                    if !editing { load() }
                })
                    .accessibilityLabel("\(channel.title) brightness")
            }
            if isColor {
                StationColorPicker(selection: Binding(get: { color }, set: { value in
                    model.setColor(entry, channel: channel, value: value)
                }), label: entry.device.hasBackground ? channel.title : "Light")
            } else {
                VStack(spacing: 7) {
                    HStack { Label("White temperature", systemImage: "thermometer.medium"); Spacer(); Text("\(Int(temperature)) K").monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
                    Slider(value: Binding(get: { temperature }, set: { value in
                        temperature = value
                        model.setTemperature(entry, channel: channel, value: Int(value))
                    }), in: 2700...6500, step: 100, onEditingChanged: { editing in
                        editingTemperature = editing
                        if !editing { load() }
                    })
                        .tint(.orange).accessibilityLabel("Task light temperature")
                }
            }
        }.frame(maxWidth: .infinity).onAppear(perform: load)
            .onChange(of: entry.device.properties) { _, _ in load() }
    }
    private func send(_ command: (String, [JSONValue])) { Task { await model.run(entry, commands: [command]) } }
    private func load() {
        // The model overlays pending adjustments on read-back. Keep a physical
        // drag stable even when another channel or a poll publishes new values.
        if !editingBrightness { brightness = LightProperties.number(entry.value("bright", channel: channel), fallback: 50, range: 1...100) }
        if !editingTemperature { temperature = LightProperties.number(entry.value("ct", channel: channel), fallback: 4000, range: 2700...6500) }
    }
}

struct AddLightView: View {
    @EnvironmentObject private var model: StationModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var deviceModel = "lamp15"
    @State private var hasSearched = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Add a light").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Turn on LAN Control in the Yeelight phone app. Your Mac and light need to share a local network.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Nearby lights").font(.headline); Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button(model.scanning ? "Searching…" : "Discover", systemImage: "antenna.radiowaves.left.and.right") { hasSearched = true; Task { await model.scan() } }.disabled(model.scanning || model.preview)
            }
            if model.discovered.isEmpty {
                Text(model.scanning ? "Listening for lights on your network…" : (hasSearched ? (model.notice ?? "No new lights found. You can also connect by IP address below.") : "Choose Discover to look for lights on your network.")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.discovered) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                    Text(device.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") { Task { await model.add(device) } }
                            }
                        }
                    }
                }.frame(maxHeight: 200)
            }
            Divider()
            Text("Connect by IP address").font(.headline)
            HStack {
                TextField("192.168.8.173", text: $host).textFieldStyle(.roundedBorder).onSubmit { connect() }
                Picker("Model", selection: $deviceModel) { Text("Monitor Light Bar Pro").tag("lamp15"); Text("Other Yeelight").tag("unknown") }.labelsHidden().frame(width: 190)
            }
            Text("Find the address in the device information page of the Yeelight app.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Spacer(); if model.connecting { ProgressView().controlSize(.small) }; Button(model.connecting ? "Connecting…" : "Connect") { connect() }.buttonStyle(.borderedProminent).disabled(host.isEmpty || model.connecting || model.preview) }
        }.padding(28).frame(width: 560).tint(stationAccent)
    }
    private func connect() { Task { if await model.addByIP(host.trimmingCharacters(in: .whitespacesAndNewlines), model: deviceModel) { dismiss() } } }
}

struct SceneTile: View {
    @EnvironmentObject private var model: StationModel
    let scene: ScenePreset
    private var symbol: String {
        switch scene.name { case "Gaming": return "gamecontroller"; case "Movie": return "film"; case "Party": return "party.popper"; case "Relax": return "cup.and.saucer"; case "Working": return "laptopcomputer"; case "Night": return "moon"; case "Light on": return "sun.max"; case "Light off": return "power"; case "Candle light": return "flame"; default: return "sparkles" }
    }
    var body: some View {
        Button { Task { await model.apply(scene) } } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(scene.name == "Gaming" ? .purple : (scene.temperature > 0 ? .orange : .pink))
                Text(scene.name).font(.subheadline.weight(.medium))
            }.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading).padding(17)
                .background(StationAppearance.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StationAppearance.cardBorder))
        }.buttonStyle(.plain).disabled(model.transitioning || model.controlling || model.scanning).accessibilityLabel("Apply \(scene.name) scene")
    }
}
