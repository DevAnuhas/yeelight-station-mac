import Foundation
import AppKit
import Combine
import XCTest
import StationCore
import StationCapture
@testable import YeelightStation

@MainActor
final class StationModelRegressionTests: XCTestCase {
    func testBeginEnumeratesTwoDisplaysAndTopologyReconcilesSavedSelectionWithoutCapture() async throws {
        let source = DisplaySource()
        let center = NotificationCenter()
        let fixture = try makeFixture(deviceCount: 0, displayProvider: { try await source.fetch() }, notificationCenter: center)
        let model = fixture.model
        model.config.displayID = 999
        XCTAssertEqual(source.calls, 0, "Initialization must stay free of capture and display lookup work.")
        model.begin(); model.begin()
        try await waitUntil("startup lists both displays") { model.displays.count == 2 }
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(model.selectedDisplay?.id, 11)
        XCTAssertEqual(try fixture.store.load().displayID, 11)
        XCTAssertTrue(model.selectDisplay(22))
        source.values.reverse()
        await model.loadDisplays()
        XCTAssertEqual(model.selectedDisplay?.id, 22, "Reordering must preserve a valid saved choice.")
        source.values = [source.values.last!]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await waitUntil("display removal reconciles selection") { model.displays.count == 1 && model.selectedDisplay?.id == 11 }
        XCTAssertFalse(model.screen.isRunning)
        XCTAssertFalse(model.audio.isRunning)
        let calls = source.calls
        await model.shutdown()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(source.calls, calls, "Shutdown must detach topology observation.")
    }

    func testDisplayEligibilityValidatesCandidatesAndMicrophoneNeedsNoDisplay() async throws {
        let fixture = try makeFixture(displayProvider: { [] })
        let model = fixture.model
        model.displays = DisplaySource.displays
        model.config.displayID = nil
        XCTAssertFalse(model.canStart(.screen))
        XCTAssertFalse(model.canStart(.music))
        XCTAssertTrue(model.canStart(.screen, displayID: 22))
        XCTAssertTrue(model.canStart(.music, displayID: 22))
        XCTAssertFalse(model.canStart(.screen, displayID: 999))
        XCTAssertFalse(model.selectDisplay(999))
        XCTAssertNil(model.config.displayID)
        model.audioSource = .microphone
        model.displays = []
        XCTAssertFalse(model.requiresDisplay(for: .music))
        XCTAssertTrue(model.displayReady(for: .music))
        XCTAssertTrue(model.canStart(.music))
        model.displays = DisplaySource.displays
        XCTAssertTrue(model.selectDisplay(11))
        await model.shutdown()
        XCTAssertTrue(model.isShuttingDown)
        XCTAssertFalse(model.selectDisplay(22))
        XCTAssertEqual(model.config.displayID, 11)
        XCTAssertFalse(model.canStart(.music))
        XCTAssertTrue(fixture.lights[0].requests.isEmpty)
    }

    func testStaleDisplayAndEnumerationFailureRejectStartBeforeStoppingOrDeviceTraffic() async throws {
        for fails in [false, true] {
            let source = DisplaySource(); source.values = []; source.fails = fails
            let fixture = try makeFixture(displayProvider: { try await source.fetch() })
            let model = fixture.model
            model.displays = DisplaySource.displays; model.config.displayID = 22
            model.mode = .music
            await model.start(.screen)
            XCTAssertEqual(model.mode, .music, "Invalid Start must not even stop the previous mode.")
            XCTAssertEqual(source.calls, 1)
            XCTAssertTrue(fixture.lights[0].requests.isEmpty)
            XCTAssertEqual(fixture.lights[0].connectionCount, 0)
            XCTAssertFalse(model.screen.isRunning)
            XCTAssertFalse(model.audio.isRunning)
            XCTAssertNotNil(model.error)
        }
    }

    func testSystemAudioWithoutDisplayRejectsBeforeAnyDeviceTraffic() async throws {
        let fixture = try makeFixture(displayProvider: { [] })
        fixture.model.config.displayID = nil
        await fixture.model.start(.music)
        XCTAssertTrue(fixture.lights[0].requests.isEmpty, "A missing display must fail before even snapshotting a device.")
        XCTAssertEqual(fixture.lights[0].connectionCount, 0)
        XCTAssertFalse(fixture.model.screen.isRunning)
        XCTAssertFalse(fixture.model.audio.isRunning)
    }

    func testBrightnessIntentStaysVisibleWithoutMarkingCardBusyDuringSlowAcknowledgement() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright")
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("brightness awaits acknowledgement") { light.requests.count == 1 }
        XCTAssertEqual(entry.value("bright", channel: .background), "42", "The slider must keep the requested value while the ACK is pending.")
        XCTAssertFalse(entry.busy, "An adjustment must leave the card responsive while its ACK/read-back is pending.")
        await model.shutdown()
    }

    func testLatestBrightnessCoalescesThroughHeldAcknowledgementAndReadBack() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", reflectsControls: true)
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("first adjustment reaches transport") { light.requests.count == 1 }
        model.setBrightness(entry, channel: .background, value: 55)
        model.setBrightness(entry, channel: .background, value: 90)
        XCTAssertEqual(entry.value("bright", channel: .background), "90")
        XCTAssertFalse(entry.busy); XCTAssertFalse(model.controlling)
        model.save()
        XCTAssertEqual(try fixture.store.load().devices[0].properties["bg_bright"], "65", "Unacknowledged drafts must not enter saved device state.")
        light.holdNextRequest(method: "get_prop"); light.acknowledgeHeldRequest()
        try await waitUntil("first read-back is held") { light.requests.count == 2 }
        XCTAssertEqual(entry.value("bright", channel: .background), "90")
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright", "get_prop"])
        light.holdNextRequest(method: "bg_set_bright"); light.acknowledgeHeldRequest()
        try await waitUntil("latest queued value follows read-back") { light.requests.count == 3 }
        XCTAssertEqual(light.requests[2].params.first, .int(90), "The unsent 55% intent must be superseded.")
        XCTAssertEqual(entry.value("bright", channel: .background), "90", "The 42% read-back must not replace newer intent.")
        light.acknowledgeHeldRequest()
        try await waitUntil("latest adjustment is confirmed", timeout: 6) { entry.confirmedProperties["bg_bright"] == "90" && light.requests.count == 4 }
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright", "get_prop", "bg_set_bright", "get_prop"])
        XCTAssertEqual(entry.value("bright", channel: .background), "90")
        XCTAssertEqual(entry.value("bright", channel: .main), "80")
        XCTAssertFalse(entry.busy); XCTAssertNil(entry.error)
    }

    func testAdjustmentsCoalesceWhileWaitingForInitialRefreshAndPreserveChannelOrder() async throws {
        let fixture = try makeFixture(holdFirstMethod: "get_prop", reflectsControls: true)
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        let refresh = Task { await model.refresh(entry) }
        try await waitUntil("initial refresh is held") { light.requests.count == 1 }
        model.setBrightness(entry, channel: .background, value: 42)
        await Task.yield()
        model.setTemperature(entry, channel: .main, value: 5000)
        model.setBrightness(entry, channel: .background, value: 90)
        XCTAssertEqual(entry.value("ct", channel: .main), "5000")
        XCTAssertEqual(entry.value("bright", channel: .background), "90")
        light.holdNextRequest(method: "set_ct_abx"); light.acknowledgeHeldRequest()
        try await waitUntil("surviving channel intent follows initial refresh") { light.requests.count == 2 }
        await refresh.value
        XCTAssertEqual(light.requests[1].method, "set_ct_abx")
        XCTAssertEqual(entry.value("bright", channel: .background), "90", "An initial stale poll must not erase pending intent.")
        XCTAssertEqual(entry.value("ct", channel: .main), "5000")
        light.acknowledgeHeldRequest()
        try await waitUntil("independent channels finish", timeout: 7) { light.requests.count == 5 && entry.confirmedProperties["bg_bright"] == "90" }
        XCTAssertEqual(light.requests.map(\.method), ["get_prop", "set_ct_abx", "get_prop", "bg_set_bright", "get_prop"])
        XCTAssertEqual(entry.value("ct", channel: .main), "5000")
        XCTAssertEqual(entry.value("bright", channel: .main), "80")
        XCTAssertEqual(entry.value("ct", channel: .background), "4000")
    }

    func testRejectedAdjustmentAndFailedReadBackRollBackButAcknowledgedTargetSurvives() async throws {
        for reject in [true, false] {
            let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", reflectsControls: true)
            let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
            model.setBrightness(entry, channel: .background, value: 42)
            try await waitUntil("adjustment awaits ACK") { light.requests.count == 1 }
            light.holdNextRequest(method: "get_prop")
            if reject { light.rejectHeldRequest(message: "Brightness rejected") }
            else { light.acknowledgeHeldRequest() }
            try await waitUntil("read-back awaits response") { light.requests.count == 2 }
            light.disconnectHeldRequest()
            try await waitUntil("failed inspection is reported") { entry.error != nil }
            XCTAssertEqual(entry.value("bright", channel: .background), reject ? "65" : "42")
            XCTAssertEqual(entry.confirmedProperties["bg_bright"], reject ? "65" : "42")
            if reject { XCTAssertTrue(try XCTUnwrap(entry.error).contains("Brightness rejected")) }
            XCTAssertNotNil(model.error); XCTAssertFalse(entry.busy)
        }
    }

    func testRejectedFirstAdjustmentDoesNotLeakOptimisticStateThroughTransportCacheOrSavedScene() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", omittedProperties: ["bg_bright"])
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("first adjustment awaits acknowledgement") { light.requests.count == 1 }
        model.saveScene(name: "Confirmed state")
        XCTAssertEqual(model.config.savedScenes.last?.actions.first?.properties["bg_bright"], "65", "An unacknowledged draft must not enter a saved snapshot.")
        light.rejectHeldRequest(message: "Brightness rejected")
        try await waitUntil("rejected command and partial read-back settle") { entry.error != nil && light.requests.count == 2 }
        XCTAssertEqual(entry.value("bright", channel: .background), "65", "Empty get_prop values must not reuse optimistic transport-cache seeds.")
        XCTAssertEqual(entry.confirmedProperties["bg_bright"], "65")
        XCTAssertEqual(try fixture.store.load().devices[0].properties["bg_bright"], "65")
    }

    func testAcknowledgedAdjustmentSurvivesOmittedReadBackAndLaterRefresh() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", reflectsControls: true, omittedProperties: ["bg_bright"])
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("adjustment awaits acknowledgement") { light.requests.count == 1 }
        XCTAssertEqual(entry.value("bright", channel: .background), "42")
        light.acknowledgeHeldRequest()
        // A scene barrier drains the accepted adjustment, including read-back.
        // Empty actions leave the device state alone after that transaction.
        await model.applySaved(SavedScene(name: "Drain adjustment", actions: []))
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright", "get_prop"])
        XCTAssertEqual(entry.value("bright", channel: .background), "42", "An omitted property must not impersonate an observation of the old cached value.")
        XCTAssertEqual(entry.confirmedProperties["bg_bright"], "42")
        XCTAssertEqual(try fixture.store.load().devices[0].properties["bg_bright"], "42")
        XCTAssertNil(entry.error); XCTAssertNil(model.error)

        await model.refresh(entry)
        model.save()
        XCTAssertEqual(entry.value("bright", channel: .background), "42", "Later inspection must preserve the last acknowledged target when the device omits it.")
        XCTAssertEqual(entry.confirmedProperties["bg_bright"], "42")
        XCTAssertEqual(try fixture.store.load().devices[0].properties["bg_bright"], "42")
        XCTAssertEqual(entry.value("bright", channel: .main), "80")
        XCTAssertNil(entry.error); XCTAssertNil(model.error)
    }

    func testSupersededRejectionKeepsNewerIntentVisibleAndStillDeliversIt() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", reflectsControls: true)
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("old adjustment awaits ACK") { light.requests.count == 1 }
        model.setBrightness(entry, channel: .background, value: 90)
        light.holdNextRequest(method: "bg_set_bright")
        light.rejectHeldRequest(message: "Old brightness rejected")
        try await waitUntil("newer intent follows rejected transaction") { light.requests.count == 3 }
        XCTAssertEqual(entry.value("bright", channel: .background), "90")
        XCTAssertTrue(try XCTUnwrap(model.error).contains("Old brightness rejected"))
        light.acknowledgeHeldRequest()
        try await waitUntil("newer intent confirms", timeout: 6) { light.requests.count == 4 && entry.confirmedProperties["bg_bright"] == "90" && entry.error == nil }
        XCTAssertEqual(entry.value("bright", channel: .background), "90")
        XCTAssertNil(entry.error)
    }

    func testSceneDrainsAdjustmentReadBackAndRejectsLateColorIntent() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", reflectsControls: true)
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("adjustment is in flight") { light.requests.count == 1 }
        var finished = false
        let scene = try XCTUnwrap(model.presets.scenes.first { $0.id == "station-6" })
        let apply = Task { await model.apply(scene); finished = true }
        try await waitUntil("scene establishes a barrier") { model.transitioning }
        model.setColor(entry, channel: .background, value: RGBColor(packed: 0x112233))
        light.holdNextRequest(method: "get_prop"); light.acknowledgeHeldRequest()
        try await waitUntil("adjustment read-back awaits response") { light.requests.count == 2 }
        XCTAssertFalse(finished)
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright", "get_prop"])
        light.acknowledgeHeldRequest()
        try await waitUntil("scene finishes after adjustment", timeout: 7) { finished }
        await apply.value
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright", "get_prop", "bg_set_scene", "get_prop"])
    }

    func testStartFreezesSystemSourceAndRevalidatesDisplayAfterPendingAdjustment() async throws {
        let source = DisplaySource()
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright", reflectsControls: true, displayProvider: { try await source.fetch() })
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.displays = source.values; model.config.displayID = 22
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("adjustment awaits ACK") { light.requests.count == 1 }
        let start = Task { await model.start(.music) }
        try await waitUntil("start validates then waits for adjustment") { model.transitioning && source.calls == 1 }
        model.audioSource = .microphone; model.config.displayID = 11; source.values = []
        light.acknowledgeHeldRequest()
        await start.value
        XCTAssertEqual(source.calls, 2, "The original system-audio source still requires a fresh display check.")
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright", "get_prop"], "A missing frozen selection must reject before startup snapshot/write/capture.")
        XCTAssertEqual(model.mode, .idle)
        XCTAssertFalse(model.audio.isRunning); XCTAssertFalse(model.screen.isRunning)
    }

    func testShutdownCancelsAdjustmentAndDropsQueuedDeviceAndPropertyIntents() async throws {
        let fixture = try makeFixture(deviceCount: 2, holdFirstMethod: "bg_set_bright")
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("adjustment awaits ACK") { light.requests.count == 1 }
        model.setBrightness(entry, channel: .background, value: 90)
        model.setTemperature(entry, channel: .main, value: 5000)
        model.setColor(model.devices[1], channel: .background, value: RGBColor(packed: 0x112233))
        await shutdownWithinDeadline(model)
        light.acknowledgeHeldRequest()
        model.setBrightness(entry, channel: .background, value: 20)
        try await assertNoTrafficAfterShutdown(fixture, unusedEntry: model.devices[1])
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright"])
        XCTAssertEqual(fixture.lights[1].connectionCount, 0)
    }

    func testStopCancelsStartupWhileSnapshotWaitsAndCannotResurrect() async throws {
        let source = DisplaySource()
        let fixture = try makeFixture(holdFirstMethod: "get_prop", displayProvider: { try await source.fetch() })
        let model = fixture.model, light = fixture.lights[0]
        model.config.displayID = 22
        let start = Task { await model.start(.screen) }
        try await waitUntil("startup snapshot awaits response") { light.requests.count == 1 }
        await model.stopSync()
        await start.value
        light.acknowledgeHeldRequest()
        XCTAssertFalse(model.transitioning); XCTAssertEqual(model.mode, .idle)
        XCTAssertEqual(light.requests.map(\.method), ["get_prop"])
        XCTAssertFalse(model.screen.isRunning); XCTAssertFalse(model.audio.isRunning)
    }

    func testShutdownCancelsStartupBeforeHeldSnapshotReturns() async throws {
        let source = DisplaySource()
        let fixture = try makeFixture(deviceCount: 2, holdFirstMethod: "get_prop", displayProvider: { try await source.fetch() })
        let model = fixture.model, light = fixture.lights[0]
        model.config.displayID = 22
        let start = Task { await model.start(.screen) }
        try await waitUntil("startup snapshot awaits response") { light.requests.count == 1 }
        await shutdownWithinDeadline(model)
        await start.value
        light.acknowledgeHeldRequest()
        try await assertNoTrafficAfterShutdown(fixture, unusedEntry: model.devices[1])
        XCTAssertEqual(light.requests.map(\.method), ["get_prop"])
        XCTAssertFalse(model.transitioning); XCTAssertEqual(model.mode, .idle)
    }

    func testMicrophoneStartBypassesDisplayLookupEntirely() async throws {
        let source = DisplaySource(); source.fails = true
        let fixture = try makeFixture(displayProvider: { try await source.fetch() })
        let model = fixture.model
        model.audioSource = .microphone; model.config.restoreOnStop = false
        await model.start(.music)
        XCTAssertEqual(source.calls, 0)
        // This peer intentionally advertises no UDP session support. Reaching
        // its snapshot proves missing displays did not block microphone startup,
        // while the unsupported session prevents opening any actual capture.
        XCTAssertEqual(fixture.lights[0].requests.map(\.method), ["get_prop"])
        XCTAssertTrue(try XCTUnwrap(model.error).contains("Realtime requires"))
        XCTAssertFalse(model.audio.isRunning)
    }

    func testStartupRestorationDoesNotWriteUnobservedCachedBrightness() async throws {
        let source = DisplaySource()
        let fixture = try makeFixture(displayProvider: { try await source.fetch() }, omittedProperties: ["bg_bright"])
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        model.config.displayID = 22
        await model.start(.screen)
        // Unsupported UDP fails before capture. Cleanup can restore the observed
        // color/power, but cannot claim the cached brightness was a snapshot.
        XCTAssertEqual(light.requests.map(\.method), ["get_prop", "bg_set_rgb", "bg_set_power"])
        XCTAssertEqual(entry.confirmedProperties["bg_bright"], "65", "An omission must retain previously confirmed local state.")
        XCTAssertFalse(model.screen.isRunning); XCTAssertFalse(model.audio.isRunning)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("Realtime requires"))
    }

    func testSceneWaitsForInFlightRefreshThenWritesBacklightScene() async throws {
        let fixture = try makeFixture(holdFirstMethod: "get_prop")
        let model = fixture.model, light = fixture.lights[0]
        let entry = try XCTUnwrap(model.devices.first)
        let scene = try XCTUnwrap(model.presets.scenes.first { $0.id == "station-6" })
        var refreshFinished = false
        let refresh = Task { await model.refresh(entry); refreshFinished = true }
        defer { refresh.cancel() }
        try await waitUntil("refresh reaches the fake light") { light.requests.count == 1 }

        var sceneFinished = false
        let apply = Task { await model.apply(scene); sceneFinished = true }
        defer { apply.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(refreshFinished)
        XCTAssertFalse(sceneFinished, "Applying a scene must wait for the refresh, not silently skip a busy entry.")
        XCTAssertEqual(light.requests.map(\.method), ["get_prop"])

        light.acknowledgeHeldRequest()
        // A scene plus its read-back needs two 1.05-second control intervals.
        try await waitUntil("scene and read-back finish", timeout: 6) { sceneFinished && refreshFinished }
        XCTAssertEqual(light.requests.map(\.method), ["get_prop", "bg_set_scene", "get_prop"])
        XCTAssertEqual(light.requests.dropFirst().first?.params, [.string("color"), .int(205), .int(100)])
        XCTAssertTrue(entry.online)
        XCTAssertEqual(entry.device.properties["power"], "on")
        XCTAssertEqual(entry.device.properties["bg_power"], "on")
        XCTAssertNil(model.error)
        XCTAssertNil(entry.error)
    }

    func testRefreshCannotAdmitSecondCriticalCommandOrClearItsBusyReservation() async throws {
        let fixture = try makeFixture(holdFirstMethod: "get_prop")
        let model = fixture.model, entry = model.devices[0], light = fixture.lights[0]
        let refresh = Task { await model.refresh(entry) }
        try await waitUntil("refresh awaits response") { light.requests.count == 1 }
        let first = Task { await model.run(entry, commands: [LightCommands.power(false, channel: .background)]) }
        try await waitUntil("first critical command reserves entry") { model.controlling }
        var secondSubmitted = false, secondFinished = false
        let second = Task {
            secondSubmitted = true
            await model.run(entry, commands: [LightCommands.brightness(42, channel: .background)])
            secondFinished = true
        }
        try await waitUntil("second critical command is submitted") { secondSubmitted }
        XCTAssertTrue(secondFinished, "An existing refresh must not let a second caller bypass the critical operation lock.")
        light.holdNextRequest(method: "bg_set_power"); light.acknowledgeHeldRequest()
        try await waitUntil("reserved command awaits ACK") { light.requests.count == 2 }
        await refresh.value
        XCTAssertTrue(entry.busy, "Refresh completion must not release a command's reservation.")
        await shutdownWithinDeadline(model)
        await first.value; await second.value
        XCTAssertEqual(light.requests.map(\.method), ["get_prop", "bg_set_power"])
    }

    func testDeviceStatusChangesRefreshAggregateUIAndRemovedLightsStopPublishing() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, entry = model.devices[0]
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        entry.online = true
        XCTAssertEqual(model.onlineCount, 1)
        XCTAssertGreaterThan(updates, 0, "The sidebar must redraw when a light becomes online, not wait for an unrelated model change.")
        model.devices.removeAll()
        updates = 0
        entry.online = false
        XCTAssertEqual(updates, 0, "Removed lights must not keep invalidating the parent UI.")
        model.devices.append(entry)
        updates = 0
        entry.online = true
        XCTAssertGreaterThan(updates, 0, "Newly added lights need the same aggregate observation.")
    }

    func testMenuControlWaitsForBackgroundPollInsteadOfDiscardingSelection() async throws {
        let fixture = try makeFixture(holdFirstMethod: "get_prop")
        let model = fixture.model, light = fixture.lights[0], entry = model.devices[0]
        let refresh = Task { await model.refresh(entry) }
        defer { refresh.cancel() }
        try await waitUntil("poll reaches the light") { light.requests.count == 1 }
        var finished = false
        let selection = Task {
            await StationMenuAction.power(deviceID: entry.id, channel: .background, on: false).executeDeviceCommand(on: model)
            finished = true
        }
        defer { selection.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished, "A selected quick action must wait for polling, rather than being silently discarded.")
        light.acknowledgeHeldRequest()
        try await waitUntil("menu action and read-back finish", timeout: 6) { finished }
        await refresh.value
        XCTAssertEqual(light.requests.map(\.method), ["get_prop", "bg_set_power", "get_prop"])
        XCTAssertEqual(light.requests.dropFirst().first?.params, [.string("off"), .string("smooth"), .int(300)])
        XCTAssertNil(model.error)
    }

    func testDelayedManualColorIntentDoesNotWriteDuringStartupTransition() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, light = fixture.lights[0]
        let entry = try XCTUnwrap(model.devices.first)
        let color = LightCommands.color(RGBColor(packed: 0x123456), channel: .background)

        // A delayed color-picker handler can arrive after startup has begun.
        // Set only the transition flag; starting capture is outside this test.
        model.transitioning = true
        await model.run(entry, commands: [color])
        XCTAssertTrue(light.requests.isEmpty)
        XCTAssertEqual(light.connectionCount, 0)

        model.transitioning = false
        await model.run(entry, commands: [color])
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_rgb", "get_prop"])
        XCTAssertEqual(light.requests.first?.params, [.int(0x123456), .string("smooth"), .int(300)])
        XCTAssertEqual(light.connectionCount, 1)
        XCTAssertTrue(entry.online)
        XCTAssertNil(model.error)
    }

    func testShutdownCancelsActiveControlBatchAndQueuedControl() async throws {
        let fixture = try makeFixture(deviceCount: 3, holdFirstMethod: "bg_set_bright")
        let model = fixture.model, light = fixture.lights[0]
        let firstEntry = model.devices[0], queuedEntry = model.devices[1], unusedEntry = model.devices[2]
        var firstFinished = false
        let first = Task {
            await model.run(firstEntry, commands: [
                LightCommands.brightness(42, channel: .background),
                LightCommands.color(RGBColor(packed: 0xAABBCC), channel: .background)
            ])
            firstFinished = true
        }
        defer { first.cancel() }
        try await waitUntil("first control awaits acknowledgement") { light.requests.count == 1 }
        var queuedFinished = false
        let queued = Task {
            await model.run(queuedEntry, commands: [LightCommands.power(false, channel: .background)])
            queuedFinished = true
        }
        defer { queued.cancel() }
        // Let the second MainActor task submit before asking the model to shut down.
        try await waitUntil("second control is submitted") { queuedEntry.busy || queuedFinished }
        XCTAssertFalse(queuedFinished)

        await shutdownWithinDeadline(model)
        try await waitUntil("control callers return") { firstFinished && queuedFinished }
        try await assertNoTrafficAfterShutdown(fixture, unusedEntry: unusedEntry)
        XCTAssertEqual(light.requests.map(\.method), ["bg_set_bright"], "Neither the batch tail nor a queued command may survive shutdown.")
        XCTAssertTrue(fixture.lights.dropFirst().allSatisfy { $0.connectionCount == 0 })
    }

    func testShutdownCancelsRefreshAndControlWaitingForThatRefresh() async throws {
        let fixture = try makeFixture(deviceCount: 2, holdFirstMethod: "get_prop")
        let model = fixture.model, light = fixture.lights[0], entry = model.devices[0]
        var refreshFinished = false
        let refresh = Task { await model.refresh(entry); refreshFinished = true }
        defer { refresh.cancel() }
        try await waitUntil("refresh awaits acknowledgement") { light.requests.count == 1 }
        var controlFinished = false
        let control = Task {
            await model.run(entry, commands: [LightCommands.power(false, channel: .background)])
            controlFinished = true
        }
        defer { control.cancel() }
        try await waitUntil("manual command is submitted") { model.controlling || controlFinished }
        XCTAssertFalse(controlFinished, "Manual control must wait for the pending refresh.")

        await shutdownWithinDeadline(model)
        try await waitUntil("refresh and waiting control return") { refreshFinished && controlFinished }
        try await assertNoTrafficAfterShutdown(fixture, unusedEntry: model.devices[1])
        XCTAssertEqual(light.requests.map(\.method), ["get_prop"])
        XCTAssertEqual(fixture.lights[1].connectionCount, 0)
    }

    func testMalformedNumericPersistedPropertiesAreRejectedWithoutOverwritingSettings() async throws {
        let invalidProperties: [(String, String)] = [
            ("bright", "nan"), ("bg_bright", "inf"), ("ct", "-inf"),
            ("bg_ct", "1e309"), ("rgb", "not-a-number"), ("bg_rgb", "16777216"),
            ("hue", "361"), ("bg_sat", "101"), ("bright", "-1")
        ]
        for (key, value) in invalidProperties {
            let fixture = try makeFixture(propertyOverride: (key, value))
            let saved = try Data(contentsOf: fixture.store.url)
            XCTAssertTrue(fixture.model.devices.isEmpty, "Unsafe persisted \(key)=\(value) must not enter the app model.")
            let error = try XCTUnwrap(fixture.model.error)
            XCTAssertTrue(error.contains("Couldn’t load settings"))
            XCTAssertTrue(error.contains("invalid values"))
            fixture.model.save()
            XCTAssertEqual(try Data(contentsOf: fixture.store.url), saved, "Rejected settings must remain available for recovery.")
            XCTAssertEqual(fixture.lights[0].connectionCount, 0)
        }
    }

    func testConcurrentManualControlsWaitForPreviousAcknowledgementAndReadBack() async throws {
        let fixture = try makeFixture(deviceCount: 2, holdFirstMethod: "bg_set_bright")
        let model = fixture.model
        var firstFinished = false
        let first = Task {
            await model.run(model.devices[0], commands: [LightCommands.brightness(42, channel: .background)])
            firstFinished = true
        }
        defer { first.cancel() }
        try await waitUntil("first light receives control") { fixture.lights[0].requests.count == 1 }
        var secondFinished = false
        let second = Task {
            await model.run(model.devices[1], commands: [LightCommands.power(false, channel: .background)])
            secondFinished = true
        }
        defer { second.cancel() }
        try await waitUntil("second control is submitted") { model.devices[1].busy || secondFinished }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(firstFinished)
        XCTAssertFalse(secondFinished)
        XCTAssertEqual(fixture.lights[1].connectionCount, 0, "A different light must still wait for the active control transaction.")

        fixture.lights[0].holdNextRequest(method: "get_prop")
        fixture.lights[0].acknowledgeHeldRequest()
        try await waitUntil("first light receives read-back") { fixture.lights[0].requests.count == 2 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(firstFinished)
        XCTAssertFalse(secondFinished)
        XCTAssertEqual(fixture.lights[1].connectionCount, 0, "The control queue must include read-back, not just the command acknowledgement.")
        fixture.lights[0].acknowledgeHeldRequest()
        try await waitUntil("both control transactions finish", timeout: 6) { firstFinished && secondFinished }
        XCTAssertEqual(fixture.lights[0].requests.map(\.method), ["bg_set_bright", "get_prop"])
        XCTAssertEqual(fixture.lights[1].requests.map(\.method), ["bg_set_power", "get_prop"])
        XCTAssertEqual(fixture.lights[1].requests.first?.params, [.string("off"), .string("smooth"), .int(300)])
        XCTAssertTrue(model.devices.allSatisfy(\.online))
        XCTAssertNil(model.error)
    }

    private struct Fixture {
        let model: StationModel
        let store: ConfigurationStore
        let lights: [LoopbackLight]
    }

    private func makeFixture(deviceCount: Int = 1, holdFirstMethod: String? = nil,
                             propertyOverride: (String, String)? = nil, reflectsControls: Bool = false,
                             displayProvider: (@MainActor () async throws -> [CaptureDisplay])? = nil,
                             notificationCenter: NotificationCenter = .default,
                             omittedProperties: Set<String> = []) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("station-app-regression-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        var lights = [LoopbackLight]()
        do {
            for index in 0..<deviceCount {
                lights.append(try LoopbackLight(holdFirstMethod: index == 0 ? holdFirstMethod : nil, reflectsControls: reflectsControls, omittedProperties: omittedProperties))
            }
            var config = StationConfiguration()
            config.devices = lights.enumerated().map { index, light in
                var properties = LoopbackLight.properties
                if let (key, value) = propertyOverride { properties[key] = value }
                return LightDevice(id: "loopback-\(index)", name: "Fake light \(index)", model: "lamp15",
                                   host: "127.0.0.1", port: light.port,
                                   support: ["bg_set_scene", "bg_set_rgb", "bg_set_bright", "bg_set_power"],
                                   properties: properties)
            }
            try store.save(config)
            let model = StationModel(store: store, previewMode: false, displayProvider: displayProvider, notificationCenter: notificationCenter)
            let fixture = Fixture(model: model, store: store, lights: lights)
            addTeardownBlock {
                await model.shutdown()
                for light in fixture.lights {
                    light.stop()
                    XCTAssertNil(light.error, "Loopback protocol fixture failed: \(String(describing: light.error))")
                }
                try FileManager.default.removeItem(at: directory)
            }
            return fixture
        } catch {
            for light in lights { light.stop() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func shutdownWithinDeadline(_ model: StationModel) async {
        let returned = expectation(description: "shutdown cancels and drains pending operations")
        let shutdown = Task { await model.shutdown(); returned.fulfill() }
        // The fake deliberately never acknowledges. Shutdown must cancel IO instead
        // of waiting out the transport's three-second request timeout.
        await fulfillment(of: [returned], timeout: 2)
        await shutdown.value
    }

    private func assertNoTrafficAfterShutdown(_ fixture: Fixture, unusedEntry: DeviceEntry) async throws {
        try await waitUntil("all accepted sockets close") {
            fixture.lights.allSatisfy { $0.activeConnectionCount == 0 }
        }
        let writes = fixture.lights.map { $0.requests.count }
        let connections = fixture.lights.map(\.connectionCount)
        // Both a previously connected entry and a never-used entry must stay inert.
        for entry in [fixture.model.devices[0], unusedEntry] {
            await fixture.model.run(entry, commands: [LightCommands.power(true, channel: .background)])
            await fixture.model.refresh(entry)
        }
        if let scene = fixture.model.presets.scenes.first { await fixture.model.apply(scene) }
        // Watch beyond the default control interval to catch delayed queued work.
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(fixture.lights.map { $0.requests.count }, writes)
        XCTAssertEqual(fixture.lights.map(\.connectionCount), connections)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 4,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for \(description)")
                throw WaitTimeout.expired
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitTimeout: Error { case expired }

    private final class DisplaySource {
        static let displays = [CaptureDisplay(id: 11, name: "Built-in", width: 1920, height: 1080),
                               CaptureDisplay(id: 22, name: "External", width: 3840, height: 2160)]
        var values = displays
        var calls = 0
        var fails = false
        func fetch() async throws -> [CaptureDisplay] {
            calls += 1
            if fails { throw NSError(domain: "Synthetic display enumeration", code: 1) }
            return values
        }
    }
}
