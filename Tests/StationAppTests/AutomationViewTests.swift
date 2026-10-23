import AppKit
import StationCore
import SwiftUI
import XCTest
@testable import YeelightStation

final class AutomationViewTests: XCTestCase {
    private let light = LightDevice(id: "synthetic-light", name: "Desk", model: "lamp15", host: "192.0.2.9")

    func testEditorRejectsMissingRequiredChoicesAndConflictingTimes() {
        var draft = ScheduleEditorDraft(deviceID: light.id)
        XCTAssertEqual(draft.validationError(device: light, presets: []), "Give this schedule a name.")
        draft.schedule.name = "Evening"
        XCTAssertNotNil(draft.validationError(device: nil, presets: []))
        draft.onEnabled = false
        draft.offEnabled = false
        XCTAssertNotNil(draft.validationError(device: light, presets: []))
        draft.onEnabled = true
        draft.offEnabled = true
        draft.offMinute = draft.onMinute
        XCTAssertEqual(draft.validationError(device: light, presets: []), "Choose different on and off times.")
        draft.offMinute = (draft.onMinute + 60) % 1440
        draft.repeatRule = .custom
        draft.customWeekdays = []
        XCTAssertEqual(draft.validationError(device: light, presets: []), "Choose at least one day to repeat.")
        draft.customWeekdays = [2, 4, 6]
        XCTAssertNil(draft.validationError(device: light, presets: []))
        XCTAssertEqual(draft.value().weekdays, [2, 4, 6])
    }

    func testOffOnlySaveClearsUnusedOnStateAndPreservesIdentity() {
        let original = LightSchedule(name: " Evening ", deviceID: light.id, channel: .background,
                                     weekdays: Set(1...7), onMinute: 22 * 60, offMinute: 7 * 60,
                                     presetID: "old-preset", customProperties: ["bg_rgb": "123"])
        var draft = ScheduleEditorDraft(schedule: original)
        draft.onEnabled = false
        draft.repeatRule = .weekdays
        let saved = draft.value()
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.name, "Evening")
        XCTAssertEqual(saved.weekdays, Set(2...6))
        XCTAssertNil(saved.onMinute)
        XCTAssertEqual(saved.offMinute, 7 * 60)
        XCTAssertNil(saved.presetID)
        XCTAssertNil(saved.customProperties)
        XCTAssertNil(draft.validationError(device: light, presets: []))
    }

    func testSceneSelectionHonorsChannelCompatibilityAndRejectsPowerOff() throws {
        let presets = try StationPresets.load().scenes
        let rgb = try XCTUnwrap(presets.first { $0.rgb > 0 && $0.powerMode != 1 })
        var draft = ScheduleEditorDraft(deviceID: light.id)
        draft.schedule.name = "Color"
        draft.onState = .preset
        draft.schedule.presetID = rgb.id
        XCTAssertNotNil(draft.validationError(device: light, presets: presets))
        draft.schedule.channel = .background
        XCTAssertNil(draft.validationError(device: light, presets: presets))
        draft.schedule.presetID = try XCTUnwrap(presets.first { $0.powerMode == 1 }).id
        XCTAssertNotNil(draft.validationError(device: light, presets: presets))
        draft.schedule.presetID = "removed-preset"
        XCTAssertNotNil(draft.validationError(device: light, presets: presets))
    }

    func testConfirmedSnapshotKeepsOnlySelectedChannelAndRejectsFlowOrIncompleteState() throws {
        let properties = ["power": "on", "bright": "82", "ct": "4100", "color_mode": "2", "flowing": "0",
                          "bg_power": "on", "bg_bright": "65", "bg_rgb": "5680127", "bg_color_mode": "1", "bg_flowing": "0", "fw_ver": "38"]
        let main = try XCTUnwrap(ScheduleEditorDraft.confirmedSnapshot(properties, device: light, channel: .main))
        XCTAssertEqual(main["ct"], "4100")
        XCTAssertNil(main["bg_rgb"])
        XCTAssertNil(main["fw_ver"])
        let background = try XCTUnwrap(ScheduleEditorDraft.confirmedSnapshot(properties, device: light, channel: .background))
        XCTAssertEqual(background["bg_rgb"], "5680127")
        XCTAssertNil(background["ct"])
        for invalid in [["bg_flowing": "1"], ["bg_power": "off"], ["bg_bright": "101"], ["bg_rgb": "broken"], ["bg_color_mode": "3"]] {
            var changed = properties
            changed.merge(invalid) { _, new in new }
            XCTAssertNil(ScheduleEditorDraft.confirmedSnapshot(changed, device: light, channel: .background), "\(invalid)")
        }
        XCTAssertNil(ScheduleEditorDraft.confirmedSnapshot([:], device: light, channel: .main))
    }

    func testChangingTargetInvalidatesCapturedStateAndPreset() {
        var draft = ScheduleEditorDraft(deviceID: light.id)
        draft.schedule.presetID = "preset"
        draft.schedule.customProperties = ["bright": "80", "ct": "4000"]
        draft.changeTarget(deviceID: "other-light", channel: .background)
        XCTAssertEqual(draft.schedule.deviceID, "other-light")
        XCTAssertEqual(draft.schedule.channel, .background)
        XCTAssertNil(draft.schedule.customProperties)
        XCTAssertNil(draft.schedule.presetID)
    }

    @MainActor
    func testSnapshotUsesConfirmedValuesInsteadOfPendingOptimisticValues() throws {
        let entry = DeviceEntry(LightDevice(id: light.id, name: "Desk", model: "lamp15", host: "192.0.2.9",
                                           properties: ["power": "on", "bright": "50", "ct": "4000"]))
        entry.device.properties["bright"] = "95"
        let snapshot = try XCTUnwrap(ScheduleEditorDraft.confirmedSnapshot(entry.confirmedProperties, device: entry.device, channel: .main))
        XCTAssertEqual(snapshot["bright"], "50")
        XCTAssertEqual(entry.device.properties["bright"], "95")
    }
}

/// Opt-in native fixtures with fake devices and an unstarted model. No polling,
/// discovery, capture, permissions, device writes, or real settings are involved.
@MainActor
final class AutomationSnapshotTests: XCTestCase {
    func testOffscreenAutomationAndDeviceSettingsFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["STATION_AUTOMATION_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STATION_AUTOMATION_SNAPSHOT_DIR to render synthetic automation fixtures.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent("unused-synthetic-settings.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = previousAppearance }
        let model = StationModel(store: ConfigurationStore(url: settingsURL), previewMode: false)
        let light = LightDevice(id: "synthetic-desk", name: "Monitor Light Bar Pro", model: "lamp15", host: "192.0.2.9",
                                support: ["set_power", "set_ct_abx", "bg_set_rgb", "set_default", "bg_set_default", "cron_add", "cron_get", "cron_del"],
                                properties: ["power": "on", "bright": "80", "ct": "4000", "fw_ver": "38", "delayoff": "18",
                                             "bg_power": "on", "bg_bright": "65", "bg_rgb": "5680127", "bg_color_mode": "1"])
        let entry = DeviceEntry(light)
        entry.online = true
        model.devices = [entry]
        model.config.devices = [light]
        try render(StationView(initialPage: .automations).environmentObject(model), size: CGSize(width: 980, height: 700),
                   to: directory.appendingPathComponent("automations-empty-980.png"))

        let schedule = LightSchedule(name: "Evening wind-down", deviceID: light.id, channel: .background,
                                     weekdays: Set(2...6), onMinute: 21 * 60, offMinute: 60,
                                     presetID: model.presets.scenes.first { $0.name == "Relax" }?.id,
                                     lastOnAttempt: .now.addingTimeInterval(-3600), lastResult: "Turn on acknowledged.")
        model.config.schedules = [schedule]
        try render(StationView(initialPage: .automations).environmentObject(model), size: CGSize(width: 980, height: 700),
                   to: directory.appendingPathComponent("automations-populated-980.png"))
        try render(ScheduleEditorView(schedule: schedule, devices: model.devices).environmentObject(model), size: CGSize(width: 600, height: 620),
                   to: directory.appendingPathComponent("schedule-editor.png"))
        for section in DeviceSettingsSection.allCases {
            try render(DeviceSettingsView(entry: entry, initialSection: section).environmentObject(model), size: CGSize(width: 600, height: 580),
                       to: directory.appendingPathComponent("device-\(section.id.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()).png"))
        }
        var timer = LightSchedule(name: "Sleep timer", deviceID: light.id, channel: .background, purpose: .sleepTimer,
                                  date: .now.addingTimeInterval(22 * 60), offMinute: 22)
        timer.lastResult = nil
        model.config.schedules.append(timer)
        try render(DeviceSettingsView(entry: entry, initialSection: .timer, initialChannel: .background).environmentObject(model), size: CGSize(width: 600, height: 580),
                   to: directory.appendingPathComponent("device-mac-timer.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path), "Opening these views must never persist or send a command.")
        XCTAssertFalse(entry.busy)
        XCTAssertNil(entry.error)
        XCTAssertEqual(entry.confirmedProperties, light.properties)
        XCTAssertFalse(model.active)
    }

    private func render<Content: View>(_ content: Content, size: CGSize, to url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = NSHostingController(rootView: content.preferredColorScheme(.dark))
        window.setContentSize(size)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let view = try XCTUnwrap(window.contentView)
        XCTAssertEqual(view.bounds.width, size.width, accuracy: 0.5)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: url)
    }
}
