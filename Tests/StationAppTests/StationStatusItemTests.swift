import AppKit
import Combine
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

    func testColorPlayRequiresAnExactCurrentOrExplicitDisplay() {
        let displays = [display(), display(id: 2)]
        for state in [StationMenuState(devices: []),
                      StationMenuState(devices: [], displays: displays),
                      StationMenuState(devices: [], displays: displays, selectedDisplayID: 99)] {
            XCTAssertNil(StationMenuAction.start(.screen).startRequest(in: state))
        }
        let selected = StationMenuState(devices: [], displays: displays, selectedDisplayID: 1)
        XCTAssertEqual(StationMenuAction.start(.screen).startRequest(in: selected), .init(mode: .screen, displayID: 1))
        XCTAssertEqual(StationMenuAction.start(.screen, displayID: 2).startRequest(in: selected), .init(mode: .screen, displayID: 2))
        XCTAssertNil(StationMenuAction.start(.screen, displayID: 99).startRequest(in: selected))
        let missing = StationMenuState(devices: [], displays: displays)
        XCTAssertEqual(StationMenuAction.start(.screen, displayID: 2).startRequest(in: missing), .init(mode: .screen, displayID: 2))
        XCTAssertNil(StationMenuAction.start(.screen, audioSource: .system).startRequest(in: selected))
    }

    @MainActor
    func testColorPlayMenuKeepsDisplayLabelsIDsAndCheckmarks() throws {
        let displays = [display(), display(id: 2, name: "Studio Display", width: 5120, height: 2880)]
        let state = StationMenuState(devices: [], displays: displays, selectedDisplayID: 2)
        let item = StationSyncMenu.startItem(.screen, state: state)
        XCTAssertEqual(item.title, "Start Color Play")
        let choices = try XCTUnwrap(item.submenu?.items)
        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(item.representedObject)
        XCTAssertEqual(choices.map(\.title), ["Built-in Display · 2560 × 1600", "Studio Display · 5120 × 2880"])
        XCTAssertEqual(choices.map(\.state), [.off, .on])
        for (choice, display) in zip(choices, displays) {
            XCTAssertTrue(choice.isEnabled)
            let action = try XCTUnwrap(choice.representedObject as? StationMenuAction)
            XCTAssertEqual(action, .start(.screen, displayID: display.id))
            XCTAssertEqual(action.startRequest(in: state), .init(mode: .screen, displayID: display.id))
        }
        let single = StationSyncMenu.startItem(.screen, state: StationMenuState(devices: [], displays: [display()]))
        XCTAssertNil(single.submenu)
        XCTAssertTrue(single.isEnabled)
        XCTAssertEqual(single.representedObject as? StationMenuAction, .start(.screen, displayID: 1))
        XCTAssertFalse(StationSyncMenu.startItem(.screen, state: StationMenuState(devices: [])).isEnabled)
    }

    @MainActor
    func testMusicMenuAlwaysListsSystemAudioAndNamedInputsWithoutDisplays() throws {
        let inputs = audioInputs()
        for displays in [[], [display()], [display(), display(id: 2, name: "Studio Display")]] {
            let state = StationMenuState(devices: [], displays: displays, selectedDisplayID: 99, audioInputs: inputs)
            let item = StationSyncMenu.startItem(.music, state: state)
            let choices = try XCTUnwrap(item.submenu?.items)
            XCTAssertEqual(item.title, "Start Music Flow")
            XCTAssertNil(item.representedObject)
            XCTAssertTrue(item.isEnabled, "An available microphone works without a display.")
            XCTAssertEqual(choices.map(\.title), ["System Audio", "Mac Microphone", "USB Audio"])
            XCTAssertEqual(choices.map(\.state), [.on, .off, .off])
            XCTAssertEqual(choices.map(\.isEnabled), [!displays.isEmpty, true, true])
            for (index, choice) in choices.enumerated() {
                let action = try XCTUnwrap(choice.representedObject as? StationMenuAction)
                let expected: StationMenuAction = index == 0 ? .start(.music, audioSource: .system)
                    : .start(.music, audioSource: .microphone, inputDeviceUID: inputs[index - 1].id)
                XCTAssertEqual(action, expected)
                XCTAssertNil(action.startRequest(in: state)?.displayID)
            }
        }
        let unavailable = StationSyncMenu.startItem(.music, state: StationMenuState(devices: []))
        let choices = try XCTUnwrap(unavailable.submenu?.items)
        XCTAssertEqual(choices.map(\.title), ["System Audio", "No audio input devices available"])
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertTrue(choices.allSatisfy { !$0.isEnabled })
    }

    @MainActor
    func testMusicCheckmarksResolveUIDsAndDefaultWithoutGuessingFromNames() throws {
        let first = AudioInputDevice(id: "first", name: "System Audio", isDefault: true)
        let second = AudioInputDevice(id: "second", name: "System Audio", isDefault: false)
        for (uid, expected) in [(nil, [false, true, false]), ("second", [false, false, true]), ("missing", [false, false, false])] as [(String?, [Bool])] {
            let state = StationMenuState(devices: [], audioSource: .microphone, audioInputs: [first, second], selectedAudioInputUID: uid)
            let choices = try XCTUnwrap(StationSyncMenu.startItem(.music, state: state).submenu?.items)
            XCTAssertEqual(choices.map { $0.state == .on }, expected)
            XCTAssertEqual(choices[1].representedObject as? StationMenuAction, .start(.music, audioSource: .microphone, inputDeviceUID: "first"))
            XCTAssertEqual(choices[2].representedObject as? StationMenuAction, .start(.music, audioSource: .microphone, inputDeviceUID: "second"))
        }
        let changedDefault = [AudioInputDevice(id: "second", name: "Renamed USB Audio", isDefault: true),
                              AudioInputDevice(id: "first", name: "Mac Microphone", isDefault: false)]
        let following = StationMenuState(devices: [], audioSource: .microphone, audioInputs: changedDefault)
        let pinned = StationMenuState(devices: [], audioSource: .microphone, audioInputs: changedDefault, selectedAudioInputUID: "first")
        XCTAssertEqual(try XCTUnwrap(StationSyncMenu.startItem(.music, state: following).submenu).items.map(\.state), [.off, .on, .off])
        XCTAssertEqual(try XCTUnwrap(StationSyncMenu.startItem(.music, state: pinned).submenu).items.map(\.state), [.off, .off, .on])
    }

    func testMusicIntentsSwitchSourcesUseExactInputsAndRejectDisplayPayloads() {
        let state = StationMenuState(devices: [], displays: [display()], selectedDisplayID: 99, audioInputs: audioInputs())
        let microphone = StationMenuAction.start(.music, audioSource: .microphone, inputDeviceUID: "usb")
        XCTAssertEqual(microphone.startRequest(in: state), .init(mode: .music, displayID: nil, audioSource: .microphone, inputDeviceUID: "usb"))
        let micState = StationMenuState(devices: [], displays: [display()], audioSource: .microphone, audioInputs: audioInputs(), selectedAudioInputUID: "usb")
        XCTAssertEqual(StationMenuAction.start(.music, audioSource: .system).startRequest(in: micState), .init(mode: .music, displayID: nil, audioSource: .system))
        XCTAssertEqual(StationMenuAction.start(.music).startRequest(in: micState), .init(mode: .music, displayID: nil, audioSource: .microphone, inputDeviceUID: "usb"))
        XCTAssertEqual(StationMenuAction.start(.music, audioSource: .microphone).startRequest(in: micState), .init(mode: .music, displayID: nil, audioSource: .microphone))
        XCTAssertNil(StationMenuAction.start(.music, displayID: 1, audioSource: .system).startRequest(in: state))
        XCTAssertNil(StationMenuAction.start(.music, audioSource: .system, inputDeviceUID: "usb").startRequest(in: state))
        XCTAssertNil(StationMenuAction.start(.music, inputDeviceUID: "usb").startRequest(in: state))
        XCTAssertNil(StationMenuAction.start(.music, audioSource: .microphone, inputDeviceUID: "missing").startRequest(in: state))
    }

    @MainActor
    func testEverySyncStartTooltipIsNilRecursivelyIncludingUnavailableItems() {
        let states = [StationMenuState(devices: []),
                      StationMenuState(devices: [], displays: [display()]),
                      StationMenuState(devices: [], displays: [display(), display(id: 2)], audioInputs: audioInputs()),
                      StationMenuState(devices: [], transitioning: true, displays: [display(), display(id: 2)], audioInputs: audioInputs()),
                      StationMenuState(devices: [], preview: true, displays: [display()], audioInputs: audioInputs()),
                      StationMenuState(devices: [], mode: .music, audioInputs: audioInputs())]
        for state in states {
            for mode in [SyncMode.screen, .music] {
                for terminating in [false, true] {
                    assertNoTooltips(StationSyncMenu.startItem(mode, state: state, isTerminating: terminating))
                }
            }
        }
    }

    @MainActor
    func testSavedMenuActionsRevalidateUnplugAndEveryCriticalState() throws {
        let displays = [display(), display(id: 2)]
        let inputs = audioInputs()
        let initial = StationMenuState(devices: [], displays: displays, selectedDisplayID: 2, audioInputs: inputs)
        let screen = try XCTUnwrap(StationSyncMenu.startItem(.screen, state: initial).submenu?.items.last?.representedObject as? StationMenuAction)
        let musicChoices = try XCTUnwrap(StationSyncMenu.startItem(.music, state: initial).submenu?.items)
        let musicActions = try musicChoices.map { try XCTUnwrap($0.representedObject as? StationMenuAction) }
        for (mode, action) in [(.screen, screen)] + musicActions.map({ (SyncMode.music, $0) }) {
            for changed in [StationMenuState(devices: [], mode: mode, displays: displays, selectedDisplayID: 2, audioInputs: inputs),
                            StationMenuState(devices: [], transitioning: true, displays: displays, selectedDisplayID: 2, audioInputs: inputs),
                            StationMenuState(devices: [], controlling: true, displays: displays, selectedDisplayID: 2, audioInputs: inputs),
                            StationMenuState(devices: [], scanning: true, displays: displays, selectedDisplayID: 2, audioInputs: inputs),
                            StationMenuState(devices: [], preview: true, displays: displays, selectedDisplayID: 2, audioInputs: inputs),
                            StationMenuState(devices: [], hasOutputs: false, displays: displays, selectedDisplayID: 2, audioInputs: inputs),
                            StationMenuState(devices: [], displays: displays, selectedDisplayID: 2, audioInputs: inputs, shuttingDown: true)] {
                XCTAssertNil(action.startRequest(in: changed))
            }
            XCTAssertNil(action.startRequest(in: initial, isTerminating: true))
            XCTAssertFalse(StationSyncMenu.startItem(mode, state: initial, isTerminating: true).isEnabled)
        }
        XCTAssertNil(screen.startRequest(in: StationMenuState(devices: [], displays: [display()], selectedDisplayID: 1)))
        XCTAssertNil(musicActions[0].startRequest(in: StationMenuState(devices: [], audioInputs: inputs)))
        XCTAssertNil(musicActions[2].startRequest(in: StationMenuState(devices: [], displays: displays, audioInputs: [inputs[0]])))
    }

    @MainActor
    func testMenuInspectionDoesNotEnumeratePersistObserveOrCapture() throws {
        let audio = MenuAudioCapture()
        var displayLookups = 0
        let (model, store) = try menuModel(audio: audio, displayProvider: { displayLookups += 1; return [] })
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: store.url)
        for _ in 0..<3 {
            for mode in [SyncMode.screen, .music] {
                XCTAssertNotNil(StationSyncMenu.startItem(mode, state: StationMenuState(model: model)).submenu)
            }
        }
        XCTAssertEqual(displayLookups, 0)
        XCTAssertEqual(audio.enumerations, 0)
        XCTAssertEqual(audio.observations, 0)
        XCTAssertEqual(audio.starts, 0)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(model.config.displayID, 2)
        XCTAssertNil(model.selectedAudioInputUID)
        XCTAssertFalse(model.screen.isRunning)
        XCTAssertFalse(model.audio.isRunning)
        XCTAssertFalse(model.transitioning)
    }

    @MainActor
    func testMenuPreparationPinsExactUIDSwitchesSourceAndLeavesDisplayAndStoreAlone() throws {
        let audio = MenuAudioCapture()
        let (model, store) = try menuModel(audio: audio)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: store.url)
        let choices = try XCTUnwrap(StationSyncMenu.startItem(.music, state: StationMenuState(model: model)).submenu?.items)
        let microphone = try XCTUnwrap(choices[2].representedObject as? StationMenuAction)
        XCTAssertEqual(microphone.prepareStart(on: model), .music)
        XCTAssertEqual(model.audioSource, .microphone)
        XCTAssertEqual(model.selectedAudioInputUID, "usb")
        XCTAssertEqual(model.selectedAudioInput?.id, "usb")
        let system = try XCTUnwrap(choices[0].representedObject as? StationMenuAction)
        XCTAssertEqual(system.prepareStart(on: model), .music)
        XCTAssertEqual(model.audioSource, .system)
        XCTAssertEqual(model.selectedAudioInputUID, "usb", "Switching to System Audio keeps the prior microphone choice.")
        let defaultMic = try XCTUnwrap(choices[1].representedObject as? StationMenuAction)
        XCTAssertEqual(defaultMic.prepareStart(on: model), .music)
        XCTAssertEqual(model.selectedAudioInputUID, "mac", "Clicking the named default device pins its UID.")
        XCTAssertEqual(model.config.displayID, 2)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(audio.enumerations, 0)
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(model.screen.isRunning)
    }

    @MainActor
    func testStaleAudioPreparationDoesNotChangeAnySelectionOrPersist() async throws {
        let audio = MenuAudioCapture()
        let (model, store) = try menuModel(audio: audio)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let choices = try XCTUnwrap(StationSyncMenu.startItem(.music, state: StationMenuState(model: model)).submenu?.items)
        let stale = try XCTUnwrap(choices[2].representedObject as? StationMenuAction)
        let system = try XCTUnwrap(choices[0].representedObject as? StationMenuAction)
        model.audioInputs.removeAll { $0.id == "usb" }
        model.selectedAudioInputUID = "mac"
        let before = try Data(contentsOf: store.url)
        XCTAssertNil(stale.prepareStart(on: model))
        XCTAssertEqual(model.audioSource, .system)
        XCTAssertEqual(model.selectedAudioInputUID, "mac")
        model.audioSource = .microphone; model.displays = []
        XCTAssertNil(system.prepareStart(on: model))
        XCTAssertEqual(model.audioSource, .microphone)
        XCTAssertEqual(model.selectedAudioInputUID, "mac")
        model.displays = [display()]
        let current = StationMenuAction.start(.music, audioSource: .system)
        for gate in 0..<5 {
            model.transitioning = gate == 0; model.controlling = gate == 1; model.scanning = gate == 2
            model.mode = gate == 3 ? .music : .idle
            XCTAssertNil(current.prepareStart(on: model, isTerminating: gate == 4))
            XCTAssertEqual(model.selectedAudioInputUID, "mac")
            XCTAssertEqual(model.audioSource, .microphone)
        }
        model.transitioning = false; model.controlling = false; model.scanning = false; model.mode = .idle
        await model.shutdown()
        XCTAssertNil(current.prepareStart(on: model))
        XCTAssertEqual(model.selectedAudioInputUID, "mac")
        XCTAssertEqual(model.config.displayID, 2)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(model.screen.isRunning)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testColorPreparationPersistsExactDisplayAndRejectsStaleSelection() throws {
        let audio = MenuAudioCapture()
        let (model, store) = try menuModel(audio: audio)
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        model.config.displayID = nil
        let item = StationSyncMenu.startItem(.screen, state: StationMenuState(model: model))
        let action = try XCTUnwrap(item.submenu?.items.last?.representedObject as? StationMenuAction)
        XCTAssertEqual(action.prepareStart(on: model), .screen)
        XCTAssertEqual(model.selectedDisplay?.id, 2)
        XCTAssertEqual(try store.load().displayID, 2)
        model.displays = [display()]; model.config.displayID = 1
        XCTAssertNil(action.prepareStart(on: model))
        XCTAssertEqual(model.config.displayID, 1)
        XCTAssertNil(action.prepareStart(on: model, isTerminating: true))
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(model.screen.isRunning)
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

    private func audioInputs() -> [AudioInputDevice] {
        [AudioInputDevice(id: "mac", name: "Mac Microphone", isDefault: true),
         AudioInputDevice(id: "usb", name: "USB Audio", isDefault: false)]
    }

    @MainActor
    private func assertNoTooltips(_ item: NSMenuItem, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(item.toolTip, item.title, file: file, line: line)
        for child in item.submenu?.items ?? [] { assertNoTooltips(child, file: file, line: line) }
    }

    @MainActor
    private func menuModel(audio: MenuAudioCapture,
                           displayProvider: (@MainActor () async throws -> [CaptureDisplay])? = nil) throws -> (StationModel, ConfigurationStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("station-menu-\(UUID().uuidString)")
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        var config = StationConfiguration(); config.devices = [makeLight()]; config.displayID = 2
        try store.save(config)
        let model = StationModel(store: store, previewMode: false, displayProvider: displayProvider,
                                 notificationCenter: NotificationCenter(), audioCapture: audio)
        model.displays = [display(), display(id: 2)]
        model.audioInputs = audioInputs()
        return (model, store)
    }

    private func event(id: AEEventID, property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id, targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData) }
        return event
    }
}

@MainActor
private final class MenuAudioCapture: StationAudioCapturing {
    var isRunning = false
    let lastError: String? = nil
    var failurePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var enumerations = 0
    var observations = 0
    var starts = 0

    func availableAudioInputs() throws -> [AudioInputDevice] { enumerations += 1; return [] }
    func observeInputs(onChange: @escaping @MainActor @Sendable () -> Void) throws -> (@MainActor () -> Void) {
        observations += 1; return {}
    }
    func start(source: AudioSource, displayID: UInt32?, inputDeviceUID: String?,
               onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        starts += 1
        XCTFail("Menu inspection and preparation must not start capture.")
    }
    func stop() async { isRunning = false }
}
