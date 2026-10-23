import Foundation
import Combine
import XCTest
import StationCore
@testable import YeelightStation

@MainActor
final class StationModelRegressionTests: XCTestCase {
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
                             propertyOverride: (String, String)? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("station-app-regression-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        var lights = [LoopbackLight]()
        do {
            for index in 0..<deviceCount {
                lights.append(try LoopbackLight(holdFirstMethod: index == 0 ? holdFirstMethod : nil))
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
            let model = StationModel(store: store, previewMode: false)
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
}
