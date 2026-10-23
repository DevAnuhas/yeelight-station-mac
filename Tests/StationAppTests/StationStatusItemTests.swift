import AppKit
import XCTest
import StationCapture
import StationCore
@testable import YeelightStation

final class StationStatusItemTests: XCTestCase {
    func testPowerIntentAndCheckedBrightnessKeepChannelsIndependent() throws {
        let light = makeLight(properties: ["power": "on", "bg_power": "off", "bright": "25", "bg_bright": "75"])
        let device = StationMenuState.Device(light: light, online: true, busy: false, error: nil)
        XCTAssertEqual(device.channels, [.main, .background])
        XCTAssertEqual(device.selectedBrightness(.main), 25)
        XCTAssertEqual(device.selectedBrightness(.background), 75)

        let taskLight = try XCTUnwrap(device.powerAction(.main).deviceCommand(in: [light]))
        XCTAssertEqual(taskLight.deviceID, light.id)
        XCTAssertEqual(taskLight.command.0, "set_power")
        XCTAssertEqual(taskLight.command.1, [.string("off"), .string("smooth"), .int(300)])
        let backlight = try XCTUnwrap(device.powerAction(.background).deviceCommand(in: [light]))
        XCTAssertEqual(backlight.command.0, "bg_set_power")
        XCTAssertEqual(backlight.command.1, [.string("on"), .string("smooth"), .int(300)])
    }

    func testBrightnessPresetsOnlyChangeTheSelectedChannel() throws {
        let light = makeLight()
        for channel in [LightChannel.main, .background] {
            for percent in [25, 50, 75, 100] {
                let action = StationMenuAction.brightness(deviceID: light.id, channel: channel, percent: percent)
                let resolved = try XCTUnwrap(action.deviceCommand(in: [light]))
                XCTAssertEqual(resolved.command.0, channel == .main ? "set_bright" : "bg_set_bright")
                XCTAssertEqual(resolved.command.1, [.int(percent), .string("smooth"), .int(300)])
            }
        }
        for percent in [0, 26, 101] {
            XCTAssertNil(StationMenuAction.brightness(deviceID: light.id, channel: .main, percent: percent).deviceCommand(in: [light]))
        }
    }

    func testMenuSelectionRevalidatesRemovedDevicesAndChannels() {
        let light = makeLight()
        let background = StationMenuAction.power(deviceID: light.id, channel: .background, on: true)
        XCTAssertNil(background.deviceCommand(in: []))
        let replacement = LightDevice(id: light.id, name: "Bulb", model: "color4", host: "192.0.2.1")
        XCTAssertNil(background.deviceCommand(in: [replacement]))
        XCTAssertNotNil(StationMenuAction.power(deviceID: light.id, channel: .main, on: true).deviceCommand(in: [replacement]))
        XCTAssertNil(StationMenuAction.openStation.deviceCommand(in: [light]))
    }

    func testUnknownPowerMeansExplicitOnAndNonPresetBrightnessIsNotRounded() {
        let device = StationMenuState.Device(light: makeLight(properties: ["bright": "49", "bg_bright": "nan"]),
                                             online: false, busy: false, error: nil)
        XCTAssertNil(device.power(.main))
        XCTAssertNil(device.power(.background))
        XCTAssertEqual(device.powerAction(.main), .power(deviceID: device.light.id, channel: .main, on: true))
        XCTAssertNil(device.selectedBrightness(.main))
        XCTAssertNil(device.selectedBrightness(.background))
    }

    func testSyncNeedsRoutingAndCannotRestartItsCurrentMode() {
        XCTAssertFalse(StationMenuState(devices: [], hasOutputs: false).allowsStart(.screen))
        let active = StationMenuState(devices: [], mode: .screen, displays: [display()], selectedDisplayID: 1)
        XCTAssertFalse(active.allowsStart(.screen))
        XCTAssertTrue(active.allowsStart(.music))
        XCTAssertTrue(active.allowsControl, "Explicit manual controls remain usable while syncing; model.run stops sync safely.")
        XCTAssertTrue(active.allowsStop)
        XCTAssertFalse(StationMenuState(devices: []).allowsStart(.idle))
        XCTAssertFalse(StationMenuState(devices: []).allowsStop)
    }

    func testConflictingOperationsAndPreviewBlockDeviceWritesButStartupCanBeStopped() {
        for state in [StationMenuState(devices: [], transitioning: true),
                      StationMenuState(devices: [], controlling: true),
                      StationMenuState(devices: [], scanning: true),
                      StationMenuState(devices: [], preview: true)] {
            XCTAssertFalse(state.allowsControl)
            XCTAssertFalse(state.allowsStart(.screen))
            XCTAssertFalse(state.allowsStart(.music))
        }
        XCTAssertTrue(StationMenuState(devices: [], transitioning: true).allowsStop)
    }

    func testDisplayStartsRequireAnExactCurrentOrExplicitSelection() {
        let displays = [display(), display(id: 2)]
        for mode in [SyncMode.screen, .music] {
            for state in [StationMenuState(devices: []),
                          StationMenuState(devices: [], displays: displays),
                          StationMenuState(devices: [], displays: displays, selectedDisplayID: 99)] {
                XCTAssertNil(StationMenuAction.start(mode).startRequest(in: state))
            }
            let selected = StationMenuState(devices: [], displays: displays, selectedDisplayID: 1)
            XCTAssertEqual(StationMenuAction.start(mode).startRequest(in: selected), .init(mode: mode, displayID: 1))
            XCTAssertEqual(StationMenuAction.start(mode, displayID: 2).startRequest(in: selected), .init(mode: mode, displayID: 2))
            XCTAssertNil(StationMenuAction.start(mode, displayID: 99).startRequest(in: selected), "A stale explicit choice must never fall back to the current display.")
            let missing = StationMenuState(devices: [], displays: displays)
            XCTAssertEqual(StationMenuAction.start(mode, displayID: 2).startRequest(in: missing), .init(mode: mode, displayID: 2), "A submenu choice establishes selection even when none was saved.")
        }
    }

    func testMicrophoneIsDisplayIndependentAndRejectsAnOldSystemAudioIntent() {
        for displays in [[], [display(), display(id: 2)]] {
            let state = StationMenuState(devices: [], displays: displays, selectedDisplayID: 99, audioSource: .microphone)
            XCTAssertEqual(StationMenuAction.start(.music, audioSource: .microphone).startRequest(in: state), .init(mode: .music, displayID: nil))
            XCTAssertNil(StationMenuAction.start(.screen).startRequest(in: state))
            XCTAssertNil(StationMenuAction.start(.music, displayID: 2, audioSource: .system).startRequest(in: state))
        }
    }

    @MainActor
    func testBothMultiDisplayMenusExposeExactChoicesAndTheSharedSelection() throws {
        let displays = [display(), display(id: 2, name: "Studio Display", width: 5120, height: 2880)]
        for mode in [SyncMode.screen, .music] {
            let state = StationMenuState(devices: [], displays: displays, selectedDisplayID: 2)
            let item = StationSyncMenu.startItem(mode, state: state)
            XCTAssertEqual(item.title, mode == .screen ? "Start Color Play" : "Start Music Flow")
            let choices = try XCTUnwrap(item.submenu?.items)
            XCTAssertTrue(item.isEnabled)
            XCTAssertNil(item.representedObject)
            XCTAssertEqual(choices.map(\.title), ["Built-in Display · 2560 × 1600", "Studio Display · 5120 × 2880"])
            XCTAssertEqual(choices.map(\.state), [.off, .on])
            XCTAssertTrue(choices.allSatisfy(\.isEnabled))
            for (choice, display) in zip(choices, displays) {
                let action = try XCTUnwrap(choice.representedObject as? StationMenuAction)
                XCTAssertEqual(action, .start(mode, displayID: display.id, audioSource: mode == .music ? .system : nil))
                XCTAssertEqual(action.startRequest(in: state), .init(mode: mode, displayID: display.id))
            }
            let missing = StationMenuState(devices: [], displays: displays)
            let unselected = try XCTUnwrap(StationSyncMenu.startItem(mode, state: missing).submenu)
            XCTAssertTrue(unselected.items.allSatisfy { $0.isEnabled && $0.state == .off })
        }
    }

    @MainActor
    func testSingleDisplayAndMicrophoneRemainDirectActions() throws {
        for mode in [SyncMode.screen, .music] {
            let state = StationMenuState(devices: [], displays: [display()])
            let item = StationSyncMenu.startItem(mode, state: state)
            XCTAssertNil(item.submenu)
            XCTAssertTrue(item.isEnabled)
            let action = try XCTUnwrap(item.representedObject as? StationMenuAction)
            XCTAssertEqual(action.startRequest(in: state), .init(mode: mode, displayID: 1))
        }
        let mic = StationMenuState(devices: [], displays: [display(), display(id: 2)], audioSource: .microphone)
        let item = StationSyncMenu.startItem(.music, state: mic)
        XCTAssertNil(item.submenu)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.representedObject as? StationMenuAction, .start(.music, audioSource: .microphone))
        for mode in [SyncMode.screen, .music] {
            XCTAssertFalse(StationSyncMenu.startItem(mode, state: StationMenuState(devices: [])).isEnabled)
        }
    }

    @MainActor
    func testMenuInspectionDoesNotEnumerateCaptureOrPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("station-menu-inspection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        var config = StationConfiguration(); config.devices = [makeLight()]; config.displayID = 2
        try store.save(config)
        let before = try Data(contentsOf: store.url)
        var enumerationCount = 0
        let model = StationModel(store: store, previewMode: false, displayProvider: {
            enumerationCount += 1; return []
        }, notificationCenter: NotificationCenter())
        model.displays = [display(), display(id: 2)]
        for mode in [SyncMode.screen, .music] {
            XCTAssertNotNil(StationSyncMenu.startItem(mode, state: StationMenuState(model: model)).submenu)
        }
        XCTAssertEqual(enumerationCount, 0)
        XCTAssertEqual(model.config.displayID, 2)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertFalse(model.screen.isRunning)
        XCTAssertFalse(model.audio.isRunning)
        XCTAssertFalse(model.transitioning)
    }

    @MainActor
    func testPreviouslyEnabledMenuActionsRevalidateUnplugOperationsAndShutdown() throws {
        let displays = [display(), display(id: 2)]
        for mode in [SyncMode.screen, .music] {
            let initial = StationMenuState(devices: [], displays: displays, selectedDisplayID: 2)
            let menu = StationSyncMenu.startItem(mode, state: initial)
            let choice = try XCTUnwrap(menu.submenu?.items.last)
            XCTAssertTrue(choice.isEnabled)
            let action = try XCTUnwrap(choice.representedObject as? StationMenuAction)
            for changed in [StationMenuState(devices: [], displays: [display()], selectedDisplayID: 1),
                            StationMenuState(devices: [], mode: mode, displays: displays, selectedDisplayID: 2),
                            StationMenuState(devices: [], transitioning: true, displays: displays, selectedDisplayID: 2),
                            StationMenuState(devices: [], controlling: true, displays: displays, selectedDisplayID: 2),
                            StationMenuState(devices: [], scanning: true, displays: displays, selectedDisplayID: 2),
                            StationMenuState(devices: [], preview: true, displays: displays, selectedDisplayID: 2),
                            StationMenuState(devices: [], hasOutputs: false, displays: displays, selectedDisplayID: 2),
                            StationMenuState(devices: [], displays: displays, selectedDisplayID: 2, shuttingDown: true)] {
                XCTAssertNil(action.startRequest(in: changed))
            }
            XCTAssertNil(action.startRequest(in: initial, isTerminating: true))
            XCTAssertFalse(StationSyncMenu.startItem(mode, state: initial, isTerminating: true).isEnabled)
        }
        let micAction = StationMenuAction.start(.music, audioSource: .microphone)
        XCTAssertNil(micAction.startRequest(in: StationMenuState(devices: [], displays: displays, selectedDisplayID: 2)))
        XCTAssertTrue(StationMenuState(devices: [], mode: .screen, controlling: true).allowsStop)
        XCTAssertTrue(StationMenuState(devices: [], transitioning: true).allowsStop)
    }

    @MainActor
    func testRealStartPreparationPersistsSelectionWithoutCaptureAndRejectsStaleActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("station-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        var config = StationConfiguration(); config.devices = [makeLight()]
        try store.save(config)
        let model = StationModel(store: store, previewMode: false)
        model.displays = [display(), display(id: 2)]
        for mode in [SyncMode.screen, .music] {
            model.config.displayID = nil
            let item = StationSyncMenu.startItem(mode, state: StationMenuState(model: model))
            let action = try XCTUnwrap(item.submenu?.items.last?.representedObject as? StationMenuAction)
            XCTAssertEqual(action.prepareStart(on: model), mode)
            XCTAssertEqual(model.selectedDisplay?.id, 2)
            XCTAssertEqual(try store.load().displayID, 2)
            model.displays = [display()]
            model.config.displayID = 1
            XCTAssertNil(action.prepareStart(on: model))
            XCTAssertEqual(model.config.displayID, 1)
            model.displays = [display(), display(id: 2)]
        }
        model.audioSource = .microphone; model.displays = []; model.config.displayID = 99
        let microphone = StationMenuAction.start(.music, audioSource: .microphone)
        XCTAssertEqual(microphone.prepareStart(on: model), .music)
        XCTAssertEqual(model.config.displayID, 99, "Microphone starts must not change a shared display choice.")
        model.audioSource = .system
        XCTAssertNil(microphone.prepareStart(on: model))
        model.displays = [display(), display(id: 2)]; model.config.displayID = 1
        let action = StationMenuAction.start(.screen, displayID: 2)
        model.transitioning = true
        XCTAssertNil(action.prepareStart(on: model))
        XCTAssertEqual(model.config.displayID, 1)
        model.transitioning = false
        XCTAssertNil(action.prepareStart(on: model, isTerminating: true))
        await model.shutdown()
        XCTAssertNil(action.prepareStart(on: model))
        XCTAssertEqual(model.config.displayID, 1)
        XCTAssertFalse(model.screen.isRunning)
        XCTAssertFalse(model.audio.isRunning)
        XCTAssertNil(model.error)
    }

    func testBackgroundStatusIncludesConnectionCountAndFullFailure() {
        let error = "Desk light: Timed out waiting for acknowledgement. Check LAN Control."
        let online = StationMenuState.Device(light: makeLight(), online: true, busy: false, error: nil)
        let offline = StationMenuState.Device(light: makeLight(), online: false, busy: false, error: error)
        let state = StationMenuState(devices: [online, offline], mode: .music, error: error)
        XCTAssertEqual(state.connectionStatus, "1 of 2 lights online")
        XCTAssertTrue(state.tooltip.contains("Music Flow is running"))
        XCTAssertTrue(state.tooltip.contains(error))
        XCTAssertEqual(StationMenuState(devices: []).connectionStatus, "No lights added")
        XCTAssertTrue(StationMenuState(devices: [], preview: true).status.contains("Preview mode"))
    }

    func testLoginLaunchIsQuietButOrdinaryAndDemoLaunchesOpen() {
        let login = event(id: kAEOpenApplication, property: keyAELaunchedAsLogInItem)
        XCTAssertFalse(StationLaunchPolicy(arguments: [], launchEvent: login).opensWindow)
        XCTAssertFalse(StationLaunchPolicy(arguments: ["--demo"], launchEvent: login).opensWindow)
        XCTAssertTrue(StationLaunchPolicy(arguments: [], launchEvent: nil).opensWindow)
        XCTAssertTrue(StationLaunchPolicy(arguments: ["--demo"], launchEvent: nil).opensWindow)
        // The registration preference alone is deliberately not an input.
        XCTAssertTrue(StationLaunchPolicy(arguments: [], launchEvent: event(id: kAEOpenApplication)).opensWindow)
    }

    func testDiagnosticStaysWindowlessAndOnlyLoginOpenEventSuppressesOpening() {
        let diagnostic = StationLaunchPolicy(arguments: ["--diagnose-network"], launchEvent: nil)
        XCTAssertTrue(diagnostic.diagnostic)
        XCTAssertFalse(diagnostic.opensWindow)
        let reopen = event(id: kAEReopenApplication, property: keyAELaunchedAsLogInItem)
        XCTAssertTrue(StationLaunchPolicy(arguments: [], launchEvent: reopen).opensWindow)
        let unrelated = event(id: kAEOpenApplication, property: keyAEPropData)
        XCTAssertTrue(StationLaunchPolicy(arguments: [], launchEvent: unrelated).opensWindow)
    }

    func testDockRemainsUntilBothUtilityWindowsAreClosed() {
        XCTAssertFalse(StationLaunchPolicy.showsDock(hasOpenStation: false, hasOpenSettings: false))
        XCTAssertTrue(StationLaunchPolicy.showsDock(hasOpenStation: true, hasOpenSettings: false))
        XCTAssertTrue(StationLaunchPolicy.showsDock(hasOpenStation: false, hasOpenSettings: true))
        XCTAssertTrue(StationLaunchPolicy.showsDock(hasOpenStation: true, hasOpenSettings: true))
    }

    private func makeLight(properties: [String: String] = [:]) -> LightDevice {
        LightDevice(id: "desk", name: "Desk light", model: "lamp15", host: "192.0.2.1", properties: properties)
    }

    private func display(id: UInt32 = 1, name: String = "Built-in Display", width: Int = 2560, height: Int = 1600) -> CaptureDisplay {
        CaptureDisplay(id: id, name: name, width: width, height: height)
    }

    private func event(id: AEEventID, property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id, targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData) }
        return event
    }
}
