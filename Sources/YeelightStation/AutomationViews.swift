import AppKit
import StationCore
import SwiftUI

private let automationAccent = Color(red: 0.65, green: 0.60, blue: 1.0)
private let macScheduleExplanation = "Runs on this Mac. Station must be running, your Mac awake, and the light reachable. Missed actions are skipped. Scheduled actions stop active sync."

enum ScheduleRepeatRule: String, CaseIterable, Identifiable {
    case once = "Once", daily = "Every day", weekdays = "Weekdays", custom = "Custom days"
    var id: Self { self }
}

enum ScheduleOnState: String, CaseIterable, Identifiable {
    case unchanged = "Keep light state", preset = "Preset", current = "Saved current state"
    var id: Self { self }
}

/// An editor owns a draft until the model validates and persists the whole change.
/// Creating or opening a draft never refreshes a device or captures live state.
struct ScheduleEditorDraft {
    var schedule: LightSchedule
    var repeatRule: ScheduleRepeatRule
    var customWeekdays: Set<Int>
    var onEnabled: Bool
    var offEnabled: Bool
    var onMinute: Int
    var offMinute: Int
    var onState: ScheduleOnState

    init(schedule: LightSchedule? = nil, deviceID: String = "", now: Date = Date(), calendar: Calendar = .current) {
        let upcoming = now.addingTimeInterval(5 * 60)
        let minute = calendar.component(.hour, from: upcoming) * 60 + calendar.component(.minute, from: upcoming)
        let value = schedule ?? LightSchedule(name: "", deviceID: deviceID, channel: .main, date: upcoming, onMinute: minute)
        self.schedule = value
        if value.weekdays.isEmpty { repeatRule = .once }
        else if value.weekdays == Set(1...7) { repeatRule = .daily }
        else if value.weekdays == Set(2...6) { repeatRule = .weekdays }
        else { repeatRule = .custom }
        customWeekdays = value.weekdays.isEmpty ? Set(2...6) : value.weekdays
        onEnabled = value.onMinute != nil
        offEnabled = value.offMinute != nil
        onMinute = value.onMinute ?? minute
        offMinute = value.offMinute ?? ((minute + 60) % 1440)
        onState = value.customProperties != nil ? .current : (value.presetID != nil ? .preset : .unchanged)
    }

    var weekdays: Set<Int> {
        switch repeatRule {
        case .once: return []
        case .daily: return Set(1...7)
        case .weekdays: return Set(2...6)
        case .custom: return customWeekdays
        }
    }

    func value() -> LightSchedule {
        var value = schedule
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.weekdays = weekdays
        value.onMinute = onEnabled ? onMinute : nil
        value.offMinute = offEnabled ? offMinute : nil
        if !onEnabled || onState != .preset { value.presetID = nil }
        if !onEnabled || onState != .current { value.customProperties = nil }
        return value
    }

    func validationError(device: LightDevice?, presets: [ScenePreset]) -> String? {
        guard !schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Give this schedule a name." }
        guard schedule.name.count <= 80 else { return "Use a name with 80 characters or fewer." }
        guard let device, device.id == schedule.deviceID else { return "Choose a light that is still in Station." }
        guard schedule.channel != .background || device.hasBackground else { return "This light has no RGB backlight. Choose the task light." }
        guard onEnabled || offEnabled else { return "Enable Turn on, Turn off, or both." }
        guard !onEnabled || (0...1439).contains(onMinute), !offEnabled || (0...1439).contains(offMinute) else { return "Choose a valid time for each action." }
        guard !onEnabled || !offEnabled || onMinute != offMinute else { return "Choose different on and off times." }
        guard repeatRule != .custom || !customWeekdays.isEmpty else { return "Choose at least one day to repeat." }
        guard weekdays.isSubset(of: Set(1...7)) else { return "Choose valid days of the week." }
        if onEnabled && onState == .preset {
            guard let preset = presets.first(where: { $0.id == schedule.presetID }), preset.powerMode != 1,
                  (try? SceneCompatibility.adapted(preset, device: device, channel: schedule.channel)) != nil else {
                return "Choose a preset compatible with this light channel."
            }
        }
        if onEnabled && onState == .current {
            guard let properties = schedule.customProperties,
                  Self.confirmedSnapshot(properties, device: device, channel: schedule.channel) != nil else {
                return "Save a confirmed static light state before saving this schedule."
            }
        }
        return nil
    }

    /// Retain protocol property names (including bg_) while excluding other channels
    /// and unrelated device metadata. Pending slider values never enter this input.
    static func confirmedSnapshot(_ properties: [String: String], device: LightDevice, channel: LightChannel) -> [String: String]? {
        let prefix = channel == .background ? "bg_" : ""
        func number(_ name: String, in range: ClosedRange<Int>) -> Bool {
            guard let value = properties[prefix + name], let number = Int(value) else { return false }
            return range.contains(number)
        }
        guard properties[prefix + "power"] == "on", properties[prefix + "flowing"] != "1",
              number("bright", in: 1...100) else { return nil }
        let mode = properties[prefix + "color_mode"]
        let isWhite = channel == .main && device.hasBackground
        if isWhite || mode == "2" {
            guard number("ct", in: 1700...6500) else { return nil }
        } else {
            guard mode != "3", number("rgb", in: 0...0xFFFFFF) else { return nil }
        }
        let names = ["power", "bright", "ct", "rgb", "color_mode", "flowing"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            let key = prefix + name
            return properties[key].map { (key, $0) }
        })
    }

    mutating func changeTarget(deviceID: String, channel: LightChannel) {
        schedule.deviceID = deviceID
        schedule.channel = channel
        schedule.customProperties = nil
        schedule.presetID = nil
    }
}

struct AutomationsView: View {
    @EnvironmentObject private var model: StationModel
    @State private var editor: ScheduleEditorPresentation?
    @State private var deleting: LightSchedule?

    private var schedules: [LightSchedule] { model.config.schedules.filter { $0.purpose == .schedule } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Runs on this Mac", systemImage: "desktopcomputer").font(.headline)
                    Text(macScheduleExplanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("New schedule", systemImage: "plus") { editor = .init(schedule: nil) }
                    .buttonStyle(.borderedProminent).tint(automationAccent)
                    .disabled(model.preview || model.devices.isEmpty || model.isShuttingDown)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            if schedules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.checkmark").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(automationAccent)
                    Text("Give your light a routine").font(.title3.weight(.medium))
                    Text(model.devices.isEmpty ? "Add a light, then set a time for its task light or backlight." : "Wake up to a favorite scene, or switch off when the day is done.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    if !model.devices.isEmpty {
                        Button("Create a schedule") { editor = .init(schedule: nil) }.disabled(model.preview || model.isShuttingDown)
                    }
                }.padding(36).frame(maxWidth: .infinity).automationCard()
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    VStack(spacing: 12) {
                        ForEach(schedules) { schedule in
                            ScheduleRow(schedule: schedule, edit: { editor = .init(schedule: schedule) }, delete: { deleting = schedule })
                        }
                    }
                }
            }
            Text("Need a one-off countdown? Open a light’s ••• menu and choose Sleep timer.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editor) { item in
            ScheduleEditorView(schedule: item.schedule, devices: model.devices).environmentObject(model)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "schedule")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete schedule", role: .destructive) {
                if let deleting { model.removeSchedule(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the schedule from this Mac.") }
    }
}

private struct ScheduleEditorPresentation: Identifiable {
    let id = UUID()
    let schedule: LightSchedule?
}

private struct ScheduleRow: View {
    @EnvironmentObject private var model: StationModel
    let schedule: LightSchedule
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clock").font(.title2).foregroundStyle(automationAccent).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(schedule.name).font(.headline)
                    Text("\(model.devices.first { $0.id == schedule.deviceID }?.device.displayName ?? "Light unavailable") · \(schedule.channel.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Toggle("Enabled", isOn: Binding(get: { schedule.enabled }, set: { model.setScheduleEnabled(schedule.id, enabled: $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel("Enable \(schedule.name)")
                    .disabled(model.preview || model.isShuttingDown)
                Button("Edit", action: edit).disabled(model.isShuttingDown)
                Menu {
                    Button("Delete schedule…", role: .destructive, action: delete).disabled(model.preview || model.isShuttingDown)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                    .accessibilityLabel("Options for \(schedule.name)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(scheduleRecurrence(schedule)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let minute = schedule.onMinute { Label(scheduleTime(minute), systemImage: "sun.max").accessibilityLabel("Turn on at \(scheduleTime(minute))") }
                if let minute = schedule.offMinute { Label(scheduleTime(minute), systemImage: "moon").accessibilityLabel("Turn off at \(scheduleTime(minute))") }
            }.font(.caption)
            Divider().opacity(0.5)
            if !schedule.enabled {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            } else if let next = model.nextOccurrence(for: schedule) {
                Text("Next: \(next.action == .on ? "Turn on" : "Turn off") · \(next.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(automationAccent)
            } else {
                Text("No upcoming actions").font(.caption).foregroundStyle(.secondary)
            }
            if let result = schedule.lastResult {
                Text("Last result: \(result)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let attempted = [schedule.lastOnAttempt, schedule.lastOffAttempt].compactMap({ $0 }).max() {
                Text("Last attempt: \(attempted.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(18).automationCard()
    }
}

struct ScheduleEditorView: View {
    @EnvironmentObject private var model: StationModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleEditorDraft
    @State private var saveError: String?
    @State private var snapshotError: String?
    private let isEditing: Bool

    init(schedule: LightSchedule? = nil, devices: [DeviceEntry]) {
        isEditing = schedule != nil
        _draft = State(initialValue: ScheduleEditorDraft(schedule: schedule, deviceID: devices.first?.id ?? ""))
    }

    private var entry: DeviceEntry? { model.devices.first { $0.id == draft.schedule.deviceID } }
    private var compatiblePresets: [ScenePreset] {
        guard let entry else { return [] }
        return model.presets.scenes.filter { $0.powerMode != 1 && (try? SceneCompatibility.adapted($0, device: entry.device, channel: draft.schedule.channel)) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isEditing ? "Edit schedule" : "New schedule").font(.title2.weight(.semibold))
                    Text("One light. One channel. Your routine.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AutomationGroup("Schedule") {
                        TextField("Name", text: $draft.schedule.name, prompt: Text("Evening wind-down"))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Schedule name")
                        Picker("Light", selection: Binding(get: { draft.schedule.deviceID }, set: { id in
                            draft.changeTarget(deviceID: id, channel: .main); snapshotError = nil
                        })) {
                            if entry == nil { Text("Choose a light").tag(draft.schedule.deviceID) }
                            ForEach(model.devices) { Text($0.device.displayName).tag($0.id) }
                        }
                        Picker("Channel", selection: Binding(get: { draft.schedule.channel }, set: { channel in
                            draft.changeTarget(deviceID: draft.schedule.deviceID, channel: channel); snapshotError = nil
                        })) {
                            Text(LightChannel.main.title).tag(LightChannel.main)
                            if entry?.device.hasBackground == true { Text(LightChannel.background.title).tag(LightChannel.background) }
                        }
                    }
                    AutomationGroup("When") {
                        Picker("Repeat", selection: $draft.repeatRule) {
                            ForEach(ScheduleRepeatRule.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if draft.repeatRule == .custom { weekdayPicker }
                        DatePicker(draft.repeatRule == .once ? "Date" : "Starting", selection: $draft.schedule.date, displayedComponents: .date)
                        actionRow("Turn on", enabled: $draft.onEnabled, minute: $draft.onMinute)
                        actionRow("Turn off", enabled: $draft.offEnabled, minute: $draft.offMinute)
                        if draft.onEnabled && draft.offEnabled && draft.offMinute < draft.onMinute {
                            Label("Turns off the following day.", systemImage: "moon.stars").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if draft.onEnabled {
                        AutomationGroup("When turning on") {
                            Picker("Light state", selection: $draft.onState) {
                                ForEach(ScheduleOnState.allCases) { Text($0.rawValue).tag($0) }
                            }
                            switch draft.onState {
                            case .unchanged:
                                Text("Turns on with the light’s existing brightness and color.").font(.caption).foregroundStyle(.secondary)
                            case .preset:
                                Picker("Preset", selection: Binding(get: { draft.schedule.presetID ?? "" }, set: { draft.schedule.presetID = $0.isEmpty ? nil : $0 })) {
                                    Text("Choose a preset").tag("")
                                    ForEach(compatiblePresets) { Text($0.name).tag($0.id) }
                                }
                                Text("Only presets compatible with this channel are shown.").font(.caption).foregroundStyle(.secondary)
                            case .current:
                                HStack {
                                    Text(draft.schedule.customProperties == nil ? "No state saved yet" : "Confirmed state saved")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(draft.schedule.customProperties == nil ? "Use current state" : "Replace with current") { captureState() }
                                        .disabled(entry == nil || entry?.busy == true || model.active || model.preview)
                                }
                                if let properties = draft.schedule.customProperties {
                                    Text(snapshotDescription(properties, channel: draft.schedule.channel)).font(.caption).foregroundStyle(automationAccent)
                                }
                                Text("Uses the last confirmed static state of this channel. Set the light first; turn off sync or color flow before saving its state.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let snapshotError { Text(snapshotError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                        }
                    }
                    Label(macScheduleExplanation, systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Enable schedule", isOn: $draft.schedule.enabled)
                    if model.preview { Text("Preview mode: schedules cannot be saved.").font(.caption).foregroundStyle(.secondary) }
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let saveError {
                    Text(saveError).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityLabel("Couldn’t save schedule: \(saveError)")
                }
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save schedule") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.preview || model.isShuttingDown)
                }
            }.padding(20)
        }.frame(width: 600, height: 620).background(Color(red: 0.065, green: 0.069, blue: 0.09)).tint(automationAccent)
    }

    private var weekdayPicker: some View {
        HStack(spacing: 8) {
            ForEach(weekdayOrder(), id: \.self) { day in
                Toggle(isOn: Binding(get: { draft.customWeekdays.contains(day) }, set: { selected in
                    if selected { draft.customWeekdays.insert(day) } else { draft.customWeekdays.remove(day) }
                })) { Text(Calendar.current.veryShortWeekdaySymbols[day - 1]).frame(minWidth: 20) }
                    .toggleStyle(.button).controlSize(.small)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func actionRow(_ title: String, enabled: Binding<Bool>, minute: Binding<Int>) -> some View {
        HStack {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox)
            Spacer()
            DatePicker(title, selection: Binding(get: { dateForMinute(minute.wrappedValue) }, set: { date in
                minute.wrappedValue = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
            }), displayedComponents: .hourAndMinute).labelsHidden().disabled(!enabled.wrappedValue)
                .accessibilityLabel("\(title) time")
        }
    }

    private func captureState() {
        guard let entry, !entry.busy, !model.active, !model.preview else { return }
        guard let snapshot = ScheduleEditorDraft.confirmedSnapshot(entry.confirmedProperties, device: entry.device, channel: draft.schedule.channel) else {
            snapshotError = "This channel needs to be on with confirmed brightness and a static color or white temperature. Set it in My Lights, then try again."
            return
        }
        draft.schedule.customProperties = snapshot
        snapshotError = nil
    }

    private func save() {
        guard !model.preview, !model.isShuttingDown else { return }
        if let message = draft.validationError(device: entry?.device, presets: model.presets.scenes) { saveError = message; return }
        do { try model.upsertSchedule(draft.value()); dismiss() }
        catch { saveError = error.localizedDescription }
    }
}

enum DeviceSettingsSection: String, CaseIterable, Identifiable {
    case information = "Information", timer = "Sleep timer", powerDefault = "Power-on default"
    var id: Self { self }
}

struct DeviceSettingsView: View {
    @EnvironmentObject private var model: StationModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var entry: DeviceEntry
    @State private var section: DeviceSettingsSection
    @State private var channel: LightChannel = .main
    @State private var minutes = 30
    @State private var performing = false
    @State private var capabilitiesExpanded = false

    init(entry: DeviceEntry, initialSection: DeviceSettingsSection = .information, initialChannel: LightChannel = .main) {
        self.entry = entry
        _section = State(initialValue: initialSection)
        _channel = State(initialValue: initialChannel == .background && !entry.device.hasBackground ? .main : initialChannel)
    }

    private var channels: [LightChannel] { entry.device.hasBackground ? [.main, .background] : [.main] }
    private var nativeTimer: Bool { LightDeviceFeatures.canUseDeviceTimer(entry.device, channel: channel) }
    private var localTimerRecord: LightSchedule? {
        model.config.schedules.filter { $0.purpose == .sleepTimer && $0.deviceID == entry.id && $0.channel == channel }.max { $0.date < $1.date }
    }
    private var unavailable: Bool { model.preview || model.isShuttingDown || model.transitioning || model.controlling || model.scanning || entry.busy || performing }
    private var nativeMinutes: Int? { Int(entry.value("delayoff", channel: .main) ?? "").flatMap { $0 >= 0 ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Device settings").font(.title2.weight(.semibold))
                    Text(entry.device.displayName).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Picker("Section", selection: $section) {
                ForEach(DeviceSettingsSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.preview { Label("Preview mode: device changes are disabled.", systemImage: "eye").font(.caption).foregroundStyle(.secondary) }
                    switch section {
                    case .information: information
                    case .timer: timer
                    case .powerDefault: powerDefaults
                    }
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error = entry.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if let error = model.error, error != entry.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Label(entry.online ? "Online" : "Offline", systemImage: "circle.fill").font(.caption).foregroundStyle(entry.online ? .green : .secondary)
                    Spacer()
                    if entry.busy || performing { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { perform { await model.refresh(entry) } }.disabled(unavailable)
                        .help("Read the latest reported device properties.")
                }
            }.padding(20)
        }.frame(width: 600, height: 580).background(Color(red: 0.065, green: 0.069, blue: 0.09)).tint(automationAccent)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            AutomationGroup("Reported by the light") {
                informationRow("Address", value: entry.device.host)
                informationRow("Port", value: String(entry.device.port))
                informationRow("Model", value: entry.device.model)
                informationRow("Firmware", value: reported("fw_ver"))
                informationRow("Device ID", value: entry.device.id)
            }
            AutomationGroup("Network details") {
                ForEach(["Uptime", "Wi-Fi name", "Wi-Fi signal", "MAC address"], id: \.self) { label in
                    informationRow(label, value: "Not reported over LAN")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation { capabilitiesExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(capabilitiesExpanded ? 90 : 0))
                            .foregroundStyle(.secondary).frame(width: 12).accessibilityHidden(true)
                        Text("Advertised capabilities (\(entry.device.support.count))")
                        Spacer(minLength: 0)
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(capabilitiesExpanded ? Text("Expanded") : Text("Collapsed"))
                if capabilitiesExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.device.support.isEmpty ? "No capabilities reported." : entry.device.support.sorted().joined(separator: ", "))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("Discover again in Add Light to update capabilities.").font(.caption)
                    }.foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: 18) {
            AutomationGroup("Turn off after a while") {
                Picker("Channel", selection: $channel) { ForEach(channels) { Text($0.title).tag($0) } }
                Label(nativeTimer ? "Timer on the light" : "Mac timer", systemImage: nativeTimer ? "lightbulb" : "desktopcomputer")
                    .font(.headline).foregroundStyle(automationAccent)
                Text(nativeTimer ? "Runs on the light, even if Station quits or your Mac sleeps. This channel must already be on." : "Runs on this Mac for this channel. Station must stay running and your Mac awake. Missed actions are skipped.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Stepper(value: $minutes, in: 1...60) {
                        Text("\(minutes) \(minutes == 1 ? "minute" : "minutes")").monospacedDigit()
                    }.accessibilityLabel("Sleep timer duration, 1 to 60 minutes").accessibilityValue("\(minutes) minutes")
                        .help("Choose from 1 to 60 minutes.")
                    Spacer()
                    Button("Set timer") { perform { await model.setSleepTimer(entry, channel: channel, minutes: minutes) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(unavailable || entry.value("power", channel: channel) != "on")
                }
                if entry.value("power", channel: channel) != "on" {
                    Text("Turn this channel on in My Lights before setting its timer.").font(.caption).foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                AutomationGroup("Current timer") {
                    HStack {
                        Text("Turn off · \(channel.title)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(localTimerRecord?.enabled == false ? "Clear timer" : "Cancel timer", role: .destructive) { perform { await model.cancelSleepTimer(entry, channel: channel) } }
                            .disabled(unavailable || (!nativeTimer && localTimerRecord == nil))
                    }
                    if let local = localTimerRecord {
                        Text("Mac timer · \(local.date.formatted(date: .omitted, time: .shortened))").font(.headline)
                        let remaining = max(0, Int(ceil(local.date.timeIntervalSince(context.date) / 60)))
                        Text(local.enabled ? (remaining > 0 ? "About \(remaining) minutes remaining" : "Deadline passed; missed actions are skipped") : "Timer finished or skipped")
                            .font(.caption).foregroundStyle(.secondary)
                        if let result = local.lastResult { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    if nativeTimer {
                        Text(nativeMinutes.map { $0 > 0 ? "Light reports \($0) minutes remaining" : "No active timer reported by the light" } ?? "Timer status not reported. Refresh to check.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Remaining time is the last value reported by the light.").font(.caption).foregroundStyle(.secondary)
                    } else if localTimerRecord == nil {
                        Text("No Mac timer set for this channel.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var powerDefaults: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save the current brightness and color for the next hard-power restart, such as unplugging and reconnecting the light. This does not turn the light on now.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(channels) { target in
                AutomationGroup(target.title) {
                    if LightDeviceFeatures.canSaveDefault(entry.device, channel: target) {
                        Text(entry.value("power", channel: target) == "on" ? "Save this channel’s current state to the light." : "Turn this channel on in My Lights before saving its default.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Save current as power-on default") { perform { await model.savePowerOnDefault(entry, channel: target) } }
                            .disabled(unavailable || model.active || entry.value("power", channel: target) != "on")
                            .accessibilityLabel("Save \(target.title) current state as power-on default")
                        if model.active { Text("Stop sync before saving a power-on default.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("This light does not advertise a power-on default command for this channel.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            AutomationGroup("Managed in the Yeelight app") {
                Text("Change automatic state saving and power resumption in the Yeelight app. Their LAN controls are not documented for this light.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reported(_ property: String) -> String {
        guard let value = entry.device.properties[property], !value.isEmpty else { return "Not reported over LAN" }
        return value
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(.secondary).frame(width: 105, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
        }.font(.callout)
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard !unavailable else { return }
        performing = true
        Task { await operation(); performing = false }
    }
}

private struct AutomationGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.subheadline.weight(.semibold))
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).automationCard()
    }
}

private extension View {
    func automationCard() -> some View {
        background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.065)))
    }
}

private func dateForMinute(_ minute: Int) -> Date {
    // A fixed, ordinary day keeps time-only editors independent of today's DST transition.
    let calendar = Calendar.current
    let day = calendar.date(from: DateComponents(year: 2024, month: 1, day: 15)) ?? .now
    return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
}

private func scheduleTime(_ minute: Int) -> String { dateForMinute(minute).formatted(date: .omitted, time: .shortened) }

private func weekdayOrder() -> [Int] { (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 } }

private func scheduleRecurrence(_ schedule: LightSchedule) -> String {
    if schedule.weekdays.isEmpty { return schedule.date.formatted(date: .abbreviated, time: .omitted) }
    if schedule.weekdays == Set(1...7) { return "Every day" }
    if schedule.weekdays == Set(2...6) { return "Weekdays" }
    return weekdayOrder().filter { schedule.weekdays.contains($0) }.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
}

private func snapshotDescription(_ properties: [String: String], channel: LightChannel) -> String {
    let prefix = channel == .background ? "bg_" : ""
    var values: [String] = []
    if let brightness = properties[prefix + "bright"] { values.append("\(brightness)% brightness") }
    if properties[prefix + "color_mode"] == "2" || (channel == .main && properties[prefix + "ct"] != nil) {
        if let temperature = properties[prefix + "ct"] { values.append("\(temperature) K") }
    } else if let value = properties[prefix + "rgb"], let rgb = Int(value) {
        values.append(RGBColor(packed: rgb).hex)
    }
    return values.joined(separator: " · ")
}
