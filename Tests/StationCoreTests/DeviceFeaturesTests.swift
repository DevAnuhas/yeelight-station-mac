import XCTest
@testable import StationCore

final class DeviceFeaturesTests: XCTestCase {
    private func device(support: Set<String>) -> LightDevice {
        LightDevice(id: "light-1", name: "Desk", model: "lamp15", host: "192.0.2.1", support: support)
    }

    func testDeviceTimerRequiresAllThreeExactMethodsAndMainChannel() {
        let required: Set<String> = ["cron_add", "cron_get", "cron_del"]
        XCTAssertTrue(LightDeviceFeatures.canUseDeviceTimer(device(support: required), channel: .main))
        XCTAssertFalse(LightDeviceFeatures.canUseDeviceTimer(device(support: required), channel: .background))
        for missing in required {
            XCTAssertFalse(LightDeviceFeatures.canUseDeviceTimer(device(support: required.subtracting([missing])), channel: .main))
        }
        XCTAssertFalse(LightDeviceFeatures.canUseDeviceTimer(device(support: []), channel: .main))
        let undocumented: Set<String> = ["bg_cron_add", "bg_cron_get", "bg_cron_del"]
        XCTAssertFalse(LightDeviceFeatures.canUseDeviceTimer(device(support: undocumented), channel: .main))
        XCTAssertFalse(LightDeviceFeatures.canUseDeviceTimer(device(support: required.union(undocumented)), channel: .background))
    }

    func testDefaultCapabilityChecksOnlyExactSelectedChannelMethod() {
        let mainOnly = device(support: ["set_default"])
        XCTAssertTrue(LightDeviceFeatures.canSaveDefault(mainOnly, channel: .main))
        XCTAssertFalse(LightDeviceFeatures.canSaveDefault(mainOnly, channel: .background))
        let backgroundOnly = device(support: ["bg_set_default"])
        XCTAssertFalse(LightDeviceFeatures.canSaveDefault(backgroundOnly, channel: .main))
        XCTAssertTrue(LightDeviceFeatures.canSaveDefault(backgroundOnly, channel: .background))
        for channel in LightChannel.allCases {
            XCTAssertFalse(LightDeviceFeatures.canSaveDefault(device(support: []), channel: channel))
            XCTAssertFalse(LightDeviceFeatures.canSaveDefault(device(support: ["set_power", "bg_set_power", "auto_save", "power_resume"]), channel: channel))
        }
    }

    func testSleepTimerAndCancellationUseDocumentedIntegerSchemas() throws {
        for minutes in [1, 15, 60] {
            let command = try LightDeviceFeatures.sleepTimer(minutes: minutes)
            XCTAssertEqual(command.0, "cron_add")
            XCTAssertEqual(command.1, [.int(0), .int(minutes)])
        }
        for invalid in [Int.min, -1, 0, 61, Int.max] {
            XCTAssertThrowsError(try LightDeviceFeatures.sleepTimer(minutes: invalid))
        }
        XCTAssertEqual(LightDeviceFeatures.cancelSleepTimer.0, "cron_del")
        XCTAssertEqual(LightDeviceFeatures.cancelSleepTimer.1, [.int(0)])
    }

    func testSavingDefaultUsesSelectedChannelAndNoParameters() {
        let main = LightDeviceFeatures.saveDefault(channel: .main)
        XCTAssertEqual(main.0, "set_default"); XCTAssertEqual(main.1, [])
        let background = LightDeviceFeatures.saveDefault(channel: .background)
        XCTAssertEqual(background.0, "bg_set_default"); XCTAssertEqual(background.1, [])
    }
}
