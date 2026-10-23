import AppKit
import XCTest
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
        let active = StationMenuState(devices: [], mode: .screen)
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

    private func event(id: AEEventID, property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id, targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData) }
        return event
    }
}
