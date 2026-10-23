import Combine
import Foundation
import StationCapture
import StationCore
import XCTest
@testable import YeelightStation

@MainActor
final class AutomationModelTests: XCTestCase {
    func testDueActionsRunOnceOnTheirExplicitChannelsAndPersistAttempts() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, entry = model.devices[0]
        // Routing defaults to the backlight. A main-channel schedule must ignore it.
        XCTAssertEqual(model.assignment(for: entry).channel, .background)
        let main = schedule(channel: .main, on: 481)
        let background = schedule(channel: .background, off: 482)
        try model.upsertSchedule(main)
        try model.upsertSchedule(background)
        XCTAssertEqual(fixture.light.connectionCount, 0, "Saving schedules must not inspect or write the light.")

        await tick(fixture, seconds: 59)
        XCTAssertTrue(fixture.light.requests.isEmpty)
        await tick(fixture, seconds: 60)
        await tick(fixture, seconds: 60)
        await tick(fixture, seconds: 61)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"])
        XCTAssertEqual(writes(fixture).first?.params, [.string("on"), .string("smooth"), .int(300)])
        XCTAssertEqual(try saved(main.id, fixture).lastOnAttempt, Self.start.addingTimeInterval(60))
        XCTAssertNotNil(try saved(main.id, fixture).lastResult)

        await tick(fixture, seconds: 120)
        await tick(fixture, seconds: 121)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power", "bg_set_power"])
        XCTAssertEqual(writes(fixture).last?.params, [.string("off"), .string("smooth"), .int(300)])
        XCTAssertEqual(try saved(background.id, fixture).lastOffAttempt, Self.start.addingTimeInterval(120))
        XCTAssertNil(model.error)
    }

    func testLaunchDoesNotCatchUpAnOccurrenceInsideTheNormalTickWindow() async throws {
        let past = schedule(on: 481)
        let fixture = try makeFixture(now: Self.start.addingTimeInterval(70), schedules: [past])
        XCTAssertEqual(fixture.light.connectionCount, 0)
        await tick(fixture, seconds: 71)
        XCTAssertTrue(fixture.light.requests.isEmpty, "An occurrence before model initialization must not be replayed, even if only eleven seconds old.")
        XCTAssertNil(try saved(past.id, fixture).lastOnAttempt)
        XCTAssertFalse(try saved(past.id, fixture).enabled, "A missed dated one-shot must expire.")
    }

    func testLargeClockGapSkipsAndExpiresOneShotWithoutWriting() async throws {
        let fixture = try makeFixture()
        let missed = schedule(on: 481, off: 482)
        try fixture.model.upsertSchedule(missed)
        await tick(fixture, seconds: 181)
        await tick(fixture, seconds: 182)
        let value = try saved(missed.id, fixture)
        XCTAssertFalse(value.enabled)
        XCTAssertNil(value.lastOnAttempt)
        XCTAssertNil(value.lastOffAttempt)
        XCTAssertEqual(fixture.light.connectionCount, 0, "Skipping a wake/clock gap must not even connect to the light.")
    }

    func testShortSleepSkipsAnOccurrenceEvenWithinTheAwakeTickWindow() async throws {
        let fixture = try makeFixture()
        let value = schedule(on: 481)
        try fixture.model.upsertSchedule(value)
        await tick(fixture, seconds: 59)
        fixture.model.automationWillSleep()
        await tick(fixture, seconds: 60)
        XCTAssertEqual(fixture.light.connectionCount, 0, "A tick while asleep must not start device IO.")

        fixture.clock.now = Self.start.addingTimeInterval(65)
        fixture.model.automationDidWake()
        await tick(fixture, seconds: 66)

        let missed = try saved(value.id, fixture)
        XCTAssertNil(missed.lastOnAttempt)
        XCTAssertFalse(missed.enabled)
        XCTAssertTrue(missed.lastResult?.localizedCaseInsensitiveContains("missed") == true)
        XCTAssertEqual(fixture.light.connectionCount, 0, "A seven-second sleep gap must be skipped even though it is shorter than the normal 90-second awake window.")
    }

    func testShortSleepInvalidatesTheRemainingDueBatchWhileFirstActionAwaitsACK() async throws {
        let fixture = try makeFixture(holdFirstMethod: "set_power")
        var first = schedule(on: 481)
        var second = schedule(channel: .background, on: 481)
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try fixture.model.upsertSchedule(first)
        try fixture.model.upsertSchedule(second)
        fixture.clock.now = Self.start.addingTimeInterval(60)
        let attempt = Task { await fixture.model.processAutomations(at: fixture.clock.now) }
        defer { attempt.cancel() }
        try await waitUntil("first action in the due batch waits for ACK") { writes(fixture).count == 1 }
        XCTAssertEqual(writes(fixture).first?.method, "set_power")
        XCTAssertNil(try saved(second.id, fixture).lastOnAttempt)

        fixture.clock.now = Self.start.addingTimeInterval(62)
        fixture.model.automationWillSleep()
        fixture.clock.now = Self.start.addingTimeInterval(65)
        fixture.model.automationDidWake()
        fixture.light.acknowledgeHeldRequest()
        await attempt.value

        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"], "An old due batch must not adopt the wake epoch and send its remaining action.")
        XCTAssertNil(try saved(second.id, fixture).lastOnAttempt, "An action left pending across sleep must not be claimed after wake.")
        await tick(fixture, seconds: 66)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"])
        XCTAssertNil(try saved(second.id, fixture).lastOnAttempt)
        XCTAssertFalse(try saved(second.id, fixture).enabled)
    }

    func testSpringForwardActionsAtTheSameInstantDispatchOnThenOff() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        // New York jumps from 01:59:59 EST to 03:00:00 EDT on this date.
        let beforeJump = try XCTUnwrap(formatter.date(from: "2026-03-08T06:59:59Z"))
        let afterJump = try XCTUnwrap(formatter.date(from: "2026-03-08T07:00:00Z"))
        let fixture = try makeFixture(now: beforeJump, calendar: calendar)
        var value = schedule(on: 2 * 60 + 15, off: 2 * 60 + 45)
        value.date = beforeJump
        try fixture.model.upsertSchedule(value)

        fixture.clock.now = afterJump
        await fixture.model.processAutomations(at: afterJump)

        let commands = writes(fixture)
        XCTAssertEqual(commands.map(\.method), ["set_power", "set_power"])
        XCTAssertEqual(commands.map { $0.params.first }, [.string("on"), .string("off")], "Both missing wall times resolve to 03:00; the final acknowledged power command must be off.")
        let completed = try saved(value.id, fixture)
        XCTAssertEqual(completed.lastOnAttempt, afterJump)
        XCTAssertEqual(completed.lastOffAttempt, afterJump)
        XCTAssertEqual(completed.lastResult, "Turn off acknowledged.")
        XCTAssertFalse(completed.enabled)
        fixture.clock.now = afterJump.addingTimeInterval(1)
        await fixture.model.processAutomations(at: fixture.clock.now)
        XCTAssertEqual(writes(fixture).count, 2)
    }

    func testRecurringScheduleSkipsTheGapAndRunsTheNextFutureOccurrence() async throws {
        let fixture = try makeFixture()
        var recurring = schedule(on: 481)
        recurring.weekdays = Set(1...7)
        try fixture.model.upsertSchedule(recurring)
        await tick(fixture, seconds: 181)
        XCTAssertTrue(fixture.light.requests.isEmpty)
        XCTAssertTrue(try saved(recurring.id, fixture).enabled)
        // Establish an awake tick just before tomorrow's action, then cross it.
        await tick(fixture, seconds: 86_440)
        await tick(fixture, seconds: 86_460)
        await tick(fixture, seconds: 86_461)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"])
        XCTAssertEqual(try saved(recurring.id, fixture).lastOnAttempt, Self.start.addingTimeInterval(86_460))
    }

    func testDisabledAndDeletedSchedulesNeverConnect() async throws {
        let fixture = try makeFixture()
        var disabled = schedule(on: 481)
        disabled.enabled = false
        let removed = schedule(channel: .background, off: 481)
        try fixture.model.upsertSchedule(disabled)
        try fixture.model.upsertSchedule(removed)
        fixture.model.removeSchedule(removed.id)
        await tick(fixture, seconds: 60)
        await tick(fixture, seconds: 61)
        XCTAssertEqual(try fixture.store.load().schedules.map(\.id), [disabled.id])
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testEnablingARecurringScheduleOnlyArmsFutureOccurrences() async throws {
        let fixture = try makeFixture()
        var value = schedule(on: 481)
        value.enabled = false
        value.weekdays = Set(1...7)
        try fixture.model.upsertSchedule(value)
        await tick(fixture, seconds: 65)
        fixture.model.setScheduleEnabled(value.id, enabled: true)
        await tick(fixture, seconds: 66)
        XCTAssertEqual(fixture.light.connectionCount, 0, "Enabling must not catch up the action from five seconds ago.")
        await tick(fixture, seconds: 86_440)
        await tick(fixture, seconds: 86_460)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"])
    }

    func testEnablingBetweenTicksDoesNotReplayAnEarlierOccurrence() async throws {
        let fixture = try makeFixture()
        var value = schedule(on: 481)
        value.enabled = false
        value.weekdays = Set(1...7)
        try fixture.model.upsertSchedule(value)
        await tick(fixture, seconds: 59)

        // The user enables at 08:01:05, while the last tick is still 08:00:59.
        fixture.clock.now = Self.start.addingTimeInterval(65)
        fixture.model.setScheduleEnabled(value.id, enabled: true)
        XCTAssertTrue(try saved(value.id, fixture).enabled)
        await tick(fixture, seconds: 66)

        XCTAssertTrue(writes(fixture).isEmpty, "Enabling must not replay an occurrence between the previous tick and the enable action.")
        XCTAssertNil(try saved(value.id, fixture).lastOnAttempt, "The earlier occurrence must not be claimed for a newly enabled schedule.")
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testEditingPendingDueScheduleDiscardsItsOldOccurrenceBeforeClaiming() async throws {
        let fixture = try makeFixture(holdFirstMethod: "set_power")
        var first = schedule(on: 481)
        var second = schedule(channel: .background, off: 481)
        // Both are due at 08:01. Stable IDs make the held main action run first.
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try fixture.model.upsertSchedule(first)
        try fixture.model.upsertSchedule(second)
        fixture.clock.now = Self.start.addingTimeInterval(60)
        let attempt = Task { await fixture.model.processAutomations(at: fixture.clock.now) }
        defer { attempt.cancel() }
        try await waitUntil("first due schedule waits for its ACK") { writes(fixture).count == 1 }
        XCTAssertEqual(writes(fixture).first?.method, "set_power")
        XCTAssertNil(try saved(second.id, fixture).lastOffAttempt, "The second schedule must still be pending when edited.")

        fixture.clock.now = Self.start.addingTimeInterval(61)
        second.name = "Replacement: turn backlight on later"
        second.onMinute = 482
        second.offMinute = nil
        try fixture.model.upsertSchedule(second)
        fixture.light.acknowledgeHeldRequest()
        await attempt.value

        let edited = try saved(second.id, fixture)
        XCTAssertEqual(edited.name, second.name)
        XCTAssertEqual(edited.onMinute, 482)
        XCTAssertNil(edited.offMinute)
        XCTAssertNil(edited.lastOnAttempt)
        XCTAssertNil(edited.lastOffAttempt, "An occurrence computed for the old definition must not claim the edited schedule.")
        XCTAssertNil(edited.lastResult)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"], "The old backlight-off action must not survive an edit while an earlier schedule awaits ACK.")

        await tick(fixture, seconds: 120)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power", "bg_set_power"])
        XCTAssertEqual(writes(fixture).last?.params.first, .string("on"))
        XCTAssertEqual(try saved(second.id, fixture).lastOnAttempt, Self.start.addingTimeInterval(120))
        XCTAssertNil(try saved(second.id, fixture).lastOffAttempt)
    }

    func testClaimedScheduleWaitingForAdjustmentDoesNotWriteAfterItsLatenessWindow() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_bright")
        let model = fixture.model, entry = model.devices[0]
        let value = schedule(on: 481)
        try model.upsertSchedule(value)
        model.setBrightness(entry, channel: .background, value: 42)
        try await waitUntil("manual adjustment waits for ACK") { writes(fixture).count == 1 }
        XCTAssertEqual(writes(fixture).first?.method, "bg_set_bright")

        let due = Self.start.addingTimeInterval(60)
        fixture.clock.now = due
        let attempt = Task { await model.processAutomations(at: due) }
        defer { attempt.cancel() }
        try await waitUntil("schedule is claimed and waits behind the adjustment") {
            model.controlling && model.config.schedules.first(where: { $0.id == value.id })?.lastOnAttempt == due
        }
        XCTAssertEqual(try saved(value.id, fixture).lastOnAttempt, due)
        XCTAssertEqual(writes(fixture).map(\.method), ["bg_set_bright"])

        // Acknowledgement and read-back release the queue after the occurrence
        // is 91 seconds late. The durable claim remains, but no power write runs.
        fixture.clock.now = due.addingTimeInterval(91)
        fixture.light.acknowledgeHeldRequest()
        await attempt.value
        await tick(fixture, seconds: 152)

        XCTAssertEqual(writes(fixture).map(\.method), ["bg_set_bright"])
        XCTAssertEqual(fixture.light.requests.map(\.method), ["bg_set_bright", "get_prop"])
        let missed = try saved(value.id, fixture)
        XCTAssertEqual(missed.lastOnAttempt, due, "A cancelled queued occurrence must keep its claim so it cannot retry.")
        XCTAssertTrue(missed.lastResult?.localizedCaseInsensitiveContains("failed") == true)
    }

    func testUncertainWriteIsClaimedOnDiskBeforeSendingAndNeverRetriedAfterReload() async throws {
        let fixture = try makeFixture(holdFirstMethod: "set_power")
        let value = schedule(on: 481)
        try fixture.model.upsertSchedule(value)
        fixture.clock.now = Self.start.addingTimeInterval(60)
        let attempt = Task { await fixture.model.processAutomations(at: fixture.clock.now) }
        defer { attempt.cancel() }
        try await waitUntil("scheduled command waits for acknowledgement") { writes(fixture).count == 1 }
        let claimed = try saved(value.id, fixture)
        XCTAssertEqual(claimed.lastOnAttempt, fixture.clock.now, "The durable claim must precede any possible device side effect.")
        fixture.light.disconnectHeldRequest()
        await attempt.value
        let failed = try saved(value.id, fixture)
        XCTAssertNotNil(failed.lastResult)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertEqual(failed.lastOnAttempt, claimed.lastOnAttempt)
        await tick(fixture, seconds: 61)

        let reloaded = makeModel(store: fixture.store, clock: fixture.clock, audio: fixture.audio)
        addTeardownBlock { await reloaded.shutdown() }
        let reloadedValue = try XCTUnwrap(reloaded.config.schedules.first { $0.id == value.id })
        XCTAssertEqual(reloadedValue.lastOnAttempt, claimed.lastOnAttempt)
        XCTAssertEqual(reloadedValue.lastResult, failed.lastResult)
        fixture.clock.now = Self.start.addingTimeInterval(62)
        await reloaded.processAutomations(at: fixture.clock.now)
        XCTAssertEqual(writes(fixture).count, 1, "A lost ACK is an uncertain write, never an automatic retry.")
        await reloaded.shutdown()
    }

    func testDeviceRejectionRecordsFailureWithoutRetryingTheOccurrence() async throws {
        let fixture = try makeFixture(holdFirstMethod: "bg_set_power")
        let value = schedule(channel: .background, off: 481)
        try fixture.model.upsertSchedule(value)
        fixture.clock.now = Self.start.addingTimeInterval(60)
        let attempt = Task { await fixture.model.processAutomations(at: fixture.clock.now) }
        defer { attempt.cancel() }
        try await waitUntil("scheduled backlight command waits for ACK") { writes(fixture).count == 1 }
        fixture.light.rejectHeldRequest(message: "Synthetic automation rejection")
        await attempt.value
        await tick(fixture, seconds: 61)
        let persisted = try saved(value.id, fixture)
        XCTAssertEqual(persisted.lastOffAttempt, Self.start.addingTimeInterval(60))
        XCTAssertTrue(persisted.lastResult?.localizedCaseInsensitiveContains("failed") == true)
        XCTAssertTrue(fixture.model.error?.contains("Synthetic automation rejection") == true)
        XCTAssertEqual(writes(fixture).map(\.method), ["bg_set_power"])
    }

    func testEditingScheduleResetsOldAttemptsAndPersistsTheNewDefinition() async throws {
        let fixture = try makeFixture()
        var value = schedule(on: 481)
        value.weekdays = Set(1...7)
        try fixture.model.upsertSchedule(value)
        await tick(fixture, seconds: 60)
        value = try saved(value.id, fixture)
        XCTAssertNotNil(value.lastOnAttempt)
        value.name = "Moved later"
        value.onMinute = 482
        try fixture.model.upsertSchedule(value)
        let edited = try saved(value.id, fixture)
        XCTAssertNil(edited.lastOnAttempt)
        XCTAssertNil(edited.lastOffAttempt)
        XCTAssertNil(edited.lastResult)
        XCTAssertEqual(edited.name, "Moved later")
        await tick(fixture, seconds: 120)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power", "set_power"])
    }

    func testNextOccurrenceUsesTheInjectedClockAndCalendarWithoutIO() throws {
        let fixture = try makeFixture()
        let overnight = schedule(on: 23 * 60, off: 60)
        try fixture.model.upsertSchedule(overnight)
        let evening = try XCTUnwrap(fixture.model.nextOccurrence(for: overnight))
        XCTAssertEqual(evening.action, .on)
        XCTAssertEqual(evening.date, Self.start.addingTimeInterval(15 * 3_600))
        fixture.clock.now = Self.start.addingTimeInterval(16 * 3_600)
        let morning = try XCTUnwrap(fixture.model.nextOccurrence(for: overnight))
        XCTAssertEqual(morning.action, .off)
        XCTAssertEqual(morning.date, Self.start.addingTimeInterval(17 * 3_600))
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testScheduledPowerActionStopsActiveSyncBeforeApplying() async throws {
        let fixture = try makeFixture()
        fixture.model.config.restoreOnStop = false
        try fixture.model.upsertSchedule(schedule(channel: .background, off: 481))
        // Set synthetic mode only. No capture, stream session or inventory runs.
        fixture.model.mode = .screen
        await tick(fixture, seconds: 60)
        XCTAssertEqual(fixture.model.mode, .idle)
        XCTAssertEqual(writes(fixture).map(\.method), ["bg_set_power"])
        XCTAssertEqual(writes(fixture).first?.params.first, .string("off"))
        await tick(fixture, seconds: 61)
        XCTAssertEqual(writes(fixture).count, 1, "Later ticks must not restore or repeat a scheduled power action.")
    }

    func testScheduledConfirmedBlackBacklightStateSendsRGBZero() async throws {
        let fixture = try makeFixture()
        let entry = fixture.model.devices[0]
        entry.confirmedProperties["bg_rgb"] = "0"
        entry.confirmedProperties["bg_color_mode"] = "1"
        entry.device.properties = entry.confirmedProperties
        var value = schedule(channel: .background, on: 481)
        value.customProperties = entry.confirmedProperties
        try fixture.model.upsertSchedule(value)
        await tick(fixture, seconds: 60)

        let commands = writes(fixture)
        XCTAssertEqual(commands.map(\.method), ["bg_set_rgb", "bg_set_bright", "bg_set_power"])
        XCTAssertEqual(commands.first?.params, [.int(0), .string("smooth"), .int(300)], "Black is a valid saved RGB state and must not be dropped before the power command.")
        XCTAssertEqual(commands.last?.params.first, .string("on"))
        XCTAssertEqual(try saved(value.id, fixture).customProperties?["bg_rgb"], "0")
        XCTAssertEqual(try saved(value.id, fixture).lastOnAttempt, Self.start.addingTimeInterval(60))
        XCTAssertNil(fixture.model.error)
    }

    func testNativeMainSleepTimerUsesOnlyDocumentedCronCommandsAndCanCancel() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, entry = model.devices[0]
        await model.setSleepTimer(entry, channel: .main, minutes: 7)
        XCTAssertEqual(writes(fixture).map(\.method), ["cron_add"])
        XCTAssertEqual(writes(fixture).first?.params, [.int(0), .int(7)])
        XCTAssertFalse(model.config.schedules.contains { $0.purpose == .sleepTimer }, "A device timer must not also arm a Mac timer.")
        await model.cancelSleepTimer(entry, channel: .main)
        XCTAssertEqual(writes(fixture).map(\.method), ["cron_add", "cron_del"])
        XCTAssertEqual(writes(fixture).last?.params, [.int(0)])
        XCTAssertFalse(fixture.light.requests.contains { $0.method.hasPrefix("bg_cron") })
        XCTAssertNil(model.error)
    }

    func testBacklightSleepTimerIsLocalEvenWhenMainCronIsAdvertised() async throws {
        let fixture = try makeFixture(now: Self.start.addingTimeInterval(17))
        let model = fixture.model, entry = model.devices[0]
        await model.setSleepTimer(entry, channel: .background, minutes: 1)
        let timer = try XCTUnwrap(model.sleepTimer(for: entry, channel: .background))
        XCTAssertEqual(timer.purpose, .sleepTimer)
        XCTAssertEqual(timer.date, Self.start.addingTimeInterval(77), "A Mac sleep timer preserves seconds in its exact deadline.")
        XCTAssertEqual(timer.channel, .background)
        XCTAssertEqual(fixture.light.connectionCount, 0, "Arming a Mac timer must not send background cron or power commands.")
        await tick(fixture, seconds: 76)
        XCTAssertTrue(writes(fixture).isEmpty)
        await tick(fixture, seconds: 77)
        await tick(fixture, seconds: 78)
        XCTAssertEqual(writes(fixture).map(\.method), ["bg_set_power"])
        XCTAssertEqual(writes(fixture).first?.params.first, .string("off"))
        XCTAssertNil(model.sleepTimer(for: entry, channel: .background))
    }

    func testFinishedLocalSleepTimerIsReplacedInPlaceAndItsRecordCanBeCleared() async throws {
        for firstFinish in [60.0, 120.0] {
            let fixture = try makeFixture()
            let model = fixture.model, entry = model.devices[0]
            await model.setSleepTimer(entry, channel: .background, minutes: 1)
            let original = try XCTUnwrap(model.sleepTimer(for: entry, channel: .background))
            // Cover a completed timer and one missed because of a large gap.
            await tick(fixture, seconds: firstFinish)
            XCTAssertFalse(try saved(original.id, fixture).enabled)
            XCTAssertNil(model.sleepTimer(for: entry, channel: .background))
            XCTAssertEqual(try fixture.store.load().schedules.count, 1)

            await model.setSleepTimer(entry, channel: .background, minutes: 2)
            let replacement = try XCTUnwrap(model.sleepTimer(for: entry, channel: .background))
            XCTAssertEqual(replacement.id, original.id, "Replacing a completed or missed timer must reuse its record.")
            XCTAssertEqual(replacement.date, Self.start.addingTimeInterval(firstFinish + 120))
            XCTAssertNil(replacement.lastOffAttempt)
            XCTAssertNil(replacement.lastResult)
            XCTAssertEqual(model.config.schedules.count, 1)
            XCTAssertEqual(try fixture.store.load().schedules.map(\.id), [original.id])

            // The Clear action must also remove a finished record, even though
            // sleepTimer(for:) no longer returns an active countdown.
            await tick(fixture, seconds: firstFinish + 180)
            XCTAssertFalse(try saved(original.id, fixture).enabled)
            XCTAssertNil(model.sleepTimer(for: entry, channel: .background))
            let trafficBeforeClear = fixture.light.requests.count
            await model.cancelSleepTimer(entry, channel: .background)
            XCTAssertTrue(model.config.schedules.isEmpty)
            XCTAssertTrue(try fixture.store.load().schedules.isEmpty)
            XCTAssertEqual(fixture.light.requests.count, trafficBeforeClear)
        }
    }

    func testPartiallyAdvertisedCronUsesLocalMainTimerAndCancellationRemovesIt() async throws {
        let fixture = try makeFixture(support: Self.support.subtracting(["cron_get"]))
        let model = fixture.model, entry = model.devices[0]
        await model.setSleepTimer(entry, channel: .main, minutes: 1)
        let timer = try XCTUnwrap(model.sleepTimer(for: entry, channel: .main))
        XCTAssertEqual(timer.channel, .main)
        await model.cancelSleepTimer(entry, channel: .main)
        XCTAssertNil(model.sleepTimer(for: entry, channel: .main))
        XCTAssertFalse(try fixture.store.load().schedules.contains { $0.id == timer.id })
        await tick(fixture, seconds: 60)
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testNativeTimerRejectionDoesNotSilentlyFallBackToMacTimer() async throws {
        let fixture = try makeFixture(holdFirstMethod: "cron_add")
        let model = fixture.model, entry = model.devices[0]
        let request = Task { await model.setSleepTimer(entry, channel: .main, minutes: 1) }
        defer { request.cancel() }
        try await waitUntil("native timer waits for ACK") { writes(fixture).count == 1 }
        fixture.light.rejectHeldRequest(message: "Synthetic timer rejection")
        await request.value
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.sleepTimer(for: entry, channel: .main))
        XCTAssertFalse(try fixture.store.load().schedules.contains { $0.purpose == .sleepTimer })
        await tick(fixture, seconds: 60)
        XCTAssertEqual(writes(fixture).map(\.method), ["cron_add"])
    }

    func testInvalidTimerRangesAndOffChannelsRejectBeforeAnyIO() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, entry = model.devices[0]
        for channel in LightChannel.allCases {
            for minutes in [0, -1, 61, Int.max] {
                await model.setSleepTimer(entry, channel: channel, minutes: minutes)
                XCTAssertNotNil(model.error)
                model.error = nil
            }
            let key = channel == .main ? "power" : "bg_power"
            entry.device.properties[key] = "off"
            entry.confirmedProperties[key] = "off"
            await model.setSleepTimer(entry, channel: channel, minutes: 1)
            XCTAssertNotNil(model.error)
            model.error = nil
            XCTAssertNil(model.sleepTimer(for: entry, channel: channel))
        }
        XCTAssertTrue(model.config.schedules.isEmpty)
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testPowerOnDefaultSendsOnlyTheExplicitChannelCommandWithoutAutoOn() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, entry = model.devices[0]
        await model.savePowerOnDefault(entry, channel: .main)
        await model.savePowerOnDefault(entry, channel: .background)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_default", "bg_set_default"])
        XCTAssertTrue(writes(fixture).allSatisfy { $0.params.isEmpty })
        XCTAssertNil(model.error)
    }

    func testUnsupportedDefaultAndOffChannelDefaultNeverConnect() async throws {
        let fixture = try makeFixture(support: Self.support.subtracting(["set_default", "bg_set_default"]))
        let model = fixture.model, entry = model.devices[0]
        for channel in LightChannel.allCases {
            await model.savePowerOnDefault(entry, channel: channel)
            XCTAssertNotNil(model.error)
            model.error = nil
        }
        entry.device.support.formUnion(["set_default", "bg_set_default"])
        for channel in LightChannel.allCases {
            let key = channel == .main ? "power" : "bg_power"
            entry.device.properties[key] = "off"
            entry.confirmedProperties[key] = "off"
            await model.savePowerOnDefault(entry, channel: channel)
            XCTAssertNotNil(model.error)
            model.error = nil
        }
        XCTAssertEqual(fixture.light.connectionCount, 0, "Saving a default must never power a channel on to satisfy its precondition.")
    }

    func testDefaultRequiresTheExactAdvertisedMethodForEachChannel() async throws {
        for channel in LightChannel.allCases {
            let other = channel == .main ? "bg_set_default" : "set_default"
            let fixture = try makeFixture(support: Self.support.subtracting(["set_default", "bg_set_default"]).union([other]))
            await fixture.model.savePowerOnDefault(fixture.model.devices[0], channel: channel)
            XCTAssertNotNil(fixture.model.error)
            XCTAssertEqual(fixture.light.connectionCount, 0)
        }
    }

    func testSavingDefaultDuringActiveSyncIsBlockedWithoutStoppingSync() async throws {
        let fixture = try makeFixture()
        fixture.model.mode = .screen
        for channel in LightChannel.allCases {
            await fixture.model.savePowerOnDefault(fixture.model.devices[0], channel: channel)
        }
        XCTAssertEqual(fixture.model.mode, .screen)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertEqual(fixture.light.connectionCount, 0)
        fixture.model.mode = .idle
    }

    func testIncompatiblePresetIsRejectedAtSaveBeforeAnyPowerWrite() async throws {
        let fixture = try makeFixture()
        let rgb = try XCTUnwrap(fixture.model.presets.scenes.first { $0.rgb > 0 })
        var value = schedule(on: 481)
        value.presetID = rgb.id
        let original = try Data(contentsOf: fixture.store.url)
        XCTAssertThrowsError(try fixture.model.upsertSchedule(value))
        XCTAssertTrue(fixture.model.config.schedules.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), original)
        await tick(fixture, seconds: 60)
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testDispatchRevalidatesPresetBeforeItsFirstWrite() async throws {
        let rgb = try XCTUnwrap(StationPresets.load().scenes.first { $0.rgb > 0 })
        let fixture = try makeFixture(support: ["set_power", "set_scene"], modelName: "color-bulb", hasBackground: false)
        var value = schedule(on: 481)
        value.presetID = rgb.id
        try fixture.model.upsertSchedule(value)
        // Rediscovery can change the reported model after a schedule was saved.
        fixture.model.devices[0].device.model = "lamp15"
        await tick(fixture, seconds: 60)
        await tick(fixture, seconds: 61)
        XCTAssertEqual(fixture.light.connectionCount, 0, "Revalidate the entire scene before even sending set_power.")
        XCTAssertNotNil(try saved(value.id, fixture).lastResult)
    }

    func testUnavailableBackgroundChannelRejectsAtSaveAndAgainAtDispatch() async throws {
        let unavailable = try makeFixture(support: ["set_power"], modelName: "color-bulb", hasBackground: false)
        XCTAssertThrowsError(try unavailable.model.upsertSchedule(schedule(channel: .background, off: 481)))
        XCTAssertTrue(try unavailable.store.load().schedules.isEmpty)
        XCTAssertEqual(unavailable.light.connectionCount, 0)

        let changed = try makeFixture()
        let value = schedule(channel: .background, off: 481)
        try changed.model.upsertSchedule(value)
        let entry = changed.model.devices[0]
        entry.device.model = "color-bulb"
        entry.device.support = ["set_power"]
        entry.device.properties = entry.device.properties.filter { !$0.key.hasPrefix("bg_") }
        entry.confirmedProperties = entry.confirmedProperties.filter { !$0.key.hasPrefix("bg_") }
        await tick(changed, seconds: 60)
        await tick(changed, seconds: 61)
        XCTAssertEqual(changed.light.connectionCount, 0)
        XCTAssertNotNil(try saved(value.id, changed).lastResult)
    }

    func testRemovingLightAlsoRemovesItsLocalAutomations() async throws {
        let fixture = try makeFixture()
        try fixture.model.upsertSchedule(schedule(on: 481))
        await fixture.model.setSleepTimer(fixture.model.devices[0], channel: .background, minutes: 1)
        XCTAssertEqual(fixture.model.config.schedules.count, 2)
        await fixture.model.remove(fixture.model.devices[0])
        XCTAssertTrue(fixture.model.config.schedules.isEmpty)
        XCTAssertTrue(try fixture.store.load().schedules.isEmpty)
        await tick(fixture, seconds: 60)
        XCTAssertEqual(fixture.light.connectionCount, 0)
    }

    func testShutdownPreventsDueSchedulesTimersAndDefaultsFromStartingIO() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, entry = model.devices[0]
        try model.upsertSchedule(schedule(on: 481))
        await model.setSleepTimer(entry, channel: .background, minutes: 1)
        await model.shutdown()
        await tick(fixture, seconds: 60)
        await model.setSleepTimer(entry, channel: .main, minutes: 1)
        await model.cancelSleepTimer(entry, channel: .main)
        await model.savePowerOnDefault(entry, channel: .main)
        XCTAssertTrue(model.isShuttingDown)
        XCTAssertEqual(fixture.light.connectionCount, 0)
        XCTAssertTrue(fixture.light.requests.isEmpty)
    }

    func testShutdownCancelsAnAutomationAwaitingACKAndLeavesItsDurableClaim() async throws {
        let fixture = try makeFixture(holdFirstMethod: "set_power")
        let value = schedule(on: 481)
        try fixture.model.upsertSchedule(value)
        fixture.clock.now = Self.start.addingTimeInterval(60)
        let attempt = Task { await fixture.model.processAutomations(at: fixture.clock.now) }
        defer { attempt.cancel() }
        try await waitUntil("automation awaits its ACK") { writes(fixture).count == 1 }
        let returned = expectation(description: "shutdown cancels the held automation")
        let shutdown = Task { await fixture.model.shutdown(); returned.fulfill() }
        await fulfillment(of: [returned], timeout: 2)
        await shutdown.value
        await attempt.value
        await tick(fixture, seconds: 61)
        XCTAssertEqual(writes(fixture).map(\.method), ["set_power"])
        XCTAssertEqual(try saved(value.id, fixture).lastOnAttempt, Self.start.addingTimeInterval(60))
    }

    func testActionsBecomingDueDuringAcknowledgementRemainArmedForTheNextTick() async throws {
        let fixture = try makeFixture(holdFirstMethod: "set_power")
        let value = schedule(on: 481, off: 482)
        try fixture.model.upsertSchedule(value)
        await fixture.model.setSleepTimer(fixture.model.devices[0], channel: .background, minutes: 2)
        let timer = try XCTUnwrap(fixture.model.sleepTimer(for: fixture.model.devices[0], channel: .background))
        fixture.clock.now = Self.start.addingTimeInterval(60)
        let processing = Task { await fixture.model.processAutomations(at: fixture.clock.now) }
        try await waitUntil("turn-on awaits acknowledgement") { fixture.light.requests.contains { $0.method == "set_power" } }
        // Both off actions become due while this tick is suspended, but remain
        // well inside the allowed lateness window for the following tick.
        fixture.clock.now = Self.start.addingTimeInterval(125)
        fixture.light.acknowledgeHeldRequest()
        await processing.value
        XCTAssertTrue(try saved(value.id, fixture).enabled)
        XCTAssertTrue(try saved(timer.id, fixture).enabled)
        XCTAssertNil(try saved(value.id, fixture).lastOffAttempt)
        XCTAssertNil(try saved(timer.id, fixture).lastOffAttempt)
        await tick(fixture, seconds: 126)
        XCTAssertEqual(writes(fixture).count, 3)
        XCTAssertEqual(writes(fixture).filter { $0.params.first == .string("off") }.map(\.method).sorted(), ["bg_set_power", "set_power"])
        XCTAssertEqual(try saved(value.id, fixture).lastOffAttempt, Self.start.addingTimeInterval(120))
        XCTAssertEqual(try saved(timer.id, fixture).lastOffAttempt, Self.start.addingTimeInterval(120))
    }

    nonisolated private static let start = Date(timeIntervalSince1970: 1_893_484_800) // 2030-01-01 08:00 UTC
    nonisolated private static let support: Set<String> = [
        "set_power", "set_scene", "set_ct_abx", "set_bright", "set_default",
        "bg_set_power", "bg_set_scene", "bg_set_rgb", "bg_set_bright", "bg_set_default",
        "cron_add", "cron_get", "cron_del"
    ]
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func schedule(channel: LightChannel = .main, on: Int? = nil, off: Int? = nil) -> LightSchedule {
        var value = LightSchedule(name: "Test automation", deviceID: "loopback-0", channel: channel)
        value.date = Self.start
        value.onMinute = on
        value.offMinute = off
        return value
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Fixture {
        let model: StationModel
        let store: ConfigurationStore
        let light: LoopbackLight
        let clock: Clock
        let audio: InventoryGuard
    }

    private func makeFixture(now: Date = AutomationModelTests.start, schedules: [LightSchedule] = [],
                             holdFirstMethod: String? = nil, support: Set<String> = AutomationModelTests.support,
                             modelName: String = "lamp15", hasBackground: Bool = true,
                             calendar: Calendar? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("station-automation-regression-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigurationStore(url: directory.appendingPathComponent("station.json"))
        let light = try LoopbackLight(holdFirstMethod: holdFirstMethod)
        do {
            var config = StationConfiguration()
            var properties = LoopbackLight.properties
            if !hasBackground { properties = properties.filter { !$0.key.hasPrefix("bg_") } }
            config.devices = [LightDevice(id: "loopback-0", name: "Automation loopback", model: modelName,
                                         host: "127.0.0.1", port: light.port, support: support, properties: properties)]
            config.schedules = schedules
            try store.save(config)
            let clock = Clock(now), audio = InventoryGuard()
            let model = makeModel(store: store, clock: clock, audio: audio, calendar: calendar)
            let fixture = Fixture(model: model, store: store, light: light, clock: clock, audio: audio)
            addTeardownBlock {
                await model.shutdown()
                light.stop()
                XCTAssertNil(light.error, "Loopback protocol fixture failed: \(String(describing: light.error))")
                try FileManager.default.removeItem(at: directory)
            }
            return fixture
        } catch {
            light.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func makeModel(store: ConfigurationStore, clock: Clock, audio: InventoryGuard,
                           calendar: Calendar? = nil) -> StationModel {
        StationModel(store: store, previewMode: false, displayProvider: {
            XCTFail("Automation tests must not enumerate native displays.")
            return []
        }, audioCapture: audio, automationClock: { clock.now }, automationCalendar: calendar ?? Self.calendar)
    }

    private func tick(_ fixture: Fixture, seconds: TimeInterval) async {
        fixture.clock.now = Self.start.addingTimeInterval(seconds)
        await fixture.model.processAutomations(at: fixture.clock.now)
    }

    private func writes(_ fixture: Fixture) -> [LoopbackLight.Request] {
        fixture.light.requests.filter { $0.method != "get_prop" && $0.method != "cron_get" }
    }

    private func saved(_ id: UUID, _ fixture: Fixture) throws -> LightSchedule {
        try XCTUnwrap(fixture.store.load().schedules.first { $0.id == id })
    }

    private func waitUntil(_ description: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for \(description)")
                throw WaitTimeout.expired
            }
            // Only socket ACK coordination uses wall time. Scheduling uses Clock.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitTimeout: Error { case expired }

    private final class InventoryGuard: StationAudioCapturing {
        var isRunning = false
        var lastError: String? { nil }
        var failurePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        func availableAudioInputs() throws -> [AudioInputDevice] {
            XCTFail("Automation tests must not enumerate native audio inputs.")
            return []
        }
        func observeInputs(onChange: @escaping @MainActor @Sendable () -> Void) throws -> (@MainActor () -> Void) {
            XCTFail("Automation tests must not observe native audio inputs.")
            return {}
        }
        func start(source: AudioSource, displayID: UInt32?, inputDeviceUID: String?,
                   onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws {
            XCTFail("Automation tests must not start capture.")
        }
        func stop() async { isRunning = false }
    }
}
