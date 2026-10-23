import Foundation
import XCTest
@testable import StationCore

final class SchedulingTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func schedule(
        date text: String = "2026-10-23T16:45:00Z", weekdays: Set<Int> = [],
        on: Int? = 8 * 60, off: Int? = 18 * 60
    ) -> LightSchedule {
        LightSchedule(name: "Desk", deviceID: "light-1", channel: .background,
                      date: date(text), weekdays: weekdays, onMinute: on, offMinute: off)
    }

    func testOneShotUsesAnchorDayAndStrictAfterInclusiveNow() throws {
        let schedule = schedule()
        let on = date("2026-10-23T08:00:00Z"), off = date("2026-10-23T18:00:00Z")
        let next = try XCTUnwrap(SchedulePlanner.nextOccurrence(for: schedule, after: on.addingTimeInterval(-1), calendar: calendar()))
        XCTAssertEqual(next.action, .on); XCTAssertEqual(next.date, on)
        XCTAssertEqual(next.scheduleID, schedule.id)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: on, calendar: calendar())?.date, off)
        XCTAssertNil(SchedulePlanner.nextOccurrence(for: schedule, after: off, calendar: calendar()))
        let due = SchedulePlanner.dueOccurrences(for: schedule, since: on, now: off, calendar: calendar())
        XCTAssertEqual(due.map(\.action), [.off]); XCTAssertEqual(due.map(\.date), [off])
        XCTAssertEqual(SchedulePlanner.dueOccurrences(for: schedule, since: on.addingTimeInterval(-1), now: on, calendar: calendar()).map(\.date), [on])
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: schedule, since: off, now: off, calendar: calendar()).isEmpty)
    }

    func testOneShotOvernightOffSurvivesPastAnchorDay() {
        let schedule = schedule(on: 22 * 60, off: 6 * 60)
        let next = SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-10-24T02:00:00Z"), calendar: calendar())
        XCTAssertEqual(next?.action, .off); XCTAssertEqual(next?.date, date("2026-10-24T06:00:00Z"))
        XCTAssertEqual(SchedulePlanner.dueOccurrences(for: schedule, since: date("2026-10-23T21:00:00Z"), now: date("2026-10-24T06:00:00Z"), calendar: calendar()).map(\.date), [date("2026-10-23T22:00:00Z"), date("2026-10-24T06:00:00Z")])
        XCTAssertNil(SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-10-24T06:00:00Z"), calendar: calendar()))
    }

    func testRecurringOvernightOffBelongsToSelectedOnDay() {
        let schedule = schedule(weekdays: [6], on: 22 * 60, off: 6 * 60) // Friday.
        let since = date("2026-10-23T21:00:00Z"), now = date("2026-10-24T06:00:00Z")
        let due = SchedulePlanner.dueOccurrences(for: schedule, since: since, now: now, calendar: calendar())
        XCTAssertEqual(due.map(\.action), [.on, .off])
        XCTAssertEqual(due.map(\.date), [date("2026-10-23T22:00:00Z"), now])
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-10-24T02:00:00Z"), calendar: calendar())?.date, now)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: now, calendar: calendar())?.date, date("2026-10-30T22:00:00Z"))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: schedule, since: now, now: date("2026-10-25T23:00:00Z"), calendar: calendar()).isEmpty)
    }

    func testOnOnlyAndOffOnlyStayOnChosenLocalDay() {
        let zone = calendar("Asia/Colombo")
        let onOnly = schedule(weekdays: [2], on: 0, off: nil)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: onOnly, after: date("2026-10-24T00:00:00Z"), calendar: zone)?.date, date("2026-10-25T18:30:00Z"))
        let offOnly = schedule(weekdays: [6], on: nil, off: 18 * 60 + 45)
        let next = SchedulePlanner.nextOccurrence(for: offOnly, after: date("2026-10-23T00:00:00Z"), calendar: zone)
        XCTAssertEqual(next?.action, .off); XCTAssertEqual(next?.date, date("2026-10-23T13:15:00Z"))
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: offOnly, after: date("2026-10-23T13:15:00Z"), calendar: zone)?.date, date("2026-10-30T13:15:00Z"))
        let lastMinute = schedule(on: nil, off: 1439)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: lastMinute, after: date("2026-10-23T00:00:00Z"), calendar: calendar())?.date, date("2026-10-23T23:59:00Z"))
    }

    func testCalendarWeekdaysIncludeSundayAndSaturdayAndRespectStartDate() {
        let weekend = schedule(weekdays: [1, 7], on: 9 * 60, off: nil)
        let due = SchedulePlanner.dueOccurrences(for: weekend, since: date("2026-10-19T00:00:00Z"), now: date("2026-10-26T00:00:00Z"), calendar: calendar())
        XCTAssertEqual(due.map(\.date), [date("2026-10-24T09:00:00Z"), date("2026-10-25T09:00:00Z")])
        let future = schedule(date: "2026-11-02T15:00:00Z", weekdays: [2], on: 8 * 60, off: nil)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: future, after: date("2026-10-01T00:00:00Z"), calendar: calendar())?.date, date("2026-11-02T08:00:00Z"))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: future, since: date("2026-10-01T00:00:00Z"), now: date("2026-11-01T23:59:59Z"), calendar: calendar()).isEmpty)
    }

    func testPastOneShotAndInactivePollingWindowDoNotReplayMissedEvents() {
        let schedule = schedule()
        let restart = date("2026-10-24T09:00:00Z")
        XCTAssertNil(SchedulePlanner.nextOccurrence(for: schedule, after: restart, calendar: calendar()))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: schedule, since: restart, now: restart.addingTimeInterval(10), calendar: calendar()).isEmpty)
        let repeating = self.schedule(weekdays: Set(1...7))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: repeating, since: restart, now: restart.addingTimeInterval(10), calendar: calendar()).isEmpty)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: repeating, after: restart, calendar: calendar())?.date, date("2026-10-24T18:00:00Z"))
    }

    func testAttemptsSuppressEachActionIndependentlyAndPreventClockRollbackReplay() {
        var schedule = schedule(weekdays: Set(1...7))
        schedule.lastOnAttempt = date("2026-10-24T08:00:00Z")
        schedule.lastOffAttempt = date("2026-10-23T18:00:00Z")
        schedule.lastResult = "Timed out; command may have succeeded"
        let due = SchedulePlanner.dueOccurrences(for: schedule, since: date("2026-10-23T00:00:00Z"), now: date("2026-10-24T18:00:00Z"), calendar: calendar())
        XCTAssertEqual(due.map(\.action), [.off]); XCTAssertEqual(due.map(\.date), [date("2026-10-24T18:00:00Z")])
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-10-24T07:00:00Z"), calendar: calendar())?.date, date("2026-10-24T18:00:00Z"))
        schedule.offMinute = nil
        schedule.lastOnAttempt = date("2027-01-10T08:00:00Z")
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-10-24T00:00:00Z"), calendar: calendar())?.date, date("2027-01-11T08:00:00Z"))
    }

    func testOccurrenceIDsAreStableAndSeparateActionsAndSchedules() throws {
        let schedule = schedule()
        let since = date("2026-10-23T00:00:00Z"), now = date("2026-10-23T23:00:00Z")
        let events = SchedulePlanner.dueOccurrences(for: schedule, since: since, now: now, calendar: calendar())
        XCTAssertEqual(events.count, 2); XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(events.first?.id, SchedulePlanner.nextOccurrence(for: schedule, after: since, calendar: calendar())?.id)
        XCTAssertEqual(events.map(\.id), SchedulePlanner.dueOccurrences(for: schedule, since: since, now: now, calendar: calendar()).map(\.id))
        var claimed = schedule
        claimed.lastOnAttempt = try XCTUnwrap(events.first).date
        claimed.lastOffAttempt = try XCTUnwrap(events.last).date
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: claimed, since: since, now: now, calendar: calendar()).isEmpty)
        var other = schedule; other.id = UUID()
        XCTAssertNotEqual(events.first?.id, SchedulePlanner.nextOccurrence(for: other, after: since, calendar: calendar())?.id)
    }

    func testSpringDSTUsesNextValidTime() {
        let zone = calendar("America/New_York")
        let schedule = schedule(date: "2026-03-07T12:00:00Z", weekdays: [1], on: 2 * 60 + 30, off: nil)
        let expected = date("2026-03-08T07:00:00Z") // Missing 02:30 advances to 03:00 EDT.
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-03-08T05:00:00Z"), calendar: zone)?.date, expected)
        XCTAssertEqual(SchedulePlanner.dueOccurrences(for: schedule, since: expected.addingTimeInterval(-1), now: expected, calendar: zone).map(\.date), [expected])
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: expected, calendar: zone)?.date, date("2026-03-15T06:30:00Z"))
    }

    func testFallDSTUsesFirstRepeatedHourOnlyEvenWhenQueryStartsBetweenOccurrences() {
        let zone = calendar("America/New_York")
        var schedule = schedule(date: "2026-10-30T12:00:00Z", weekdays: [1], on: 90, off: nil)
        let first = date("2026-11-01T05:30:00Z"), second = date("2026-11-01T06:30:00Z")
        let since = date("2026-11-01T04:00:00Z")
        XCTAssertEqual(SchedulePlanner.dueOccurrences(for: schedule, since: since, now: second, calendar: zone).map(\.date), [first])
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: first, calendar: zone)?.date, date("2026-11-08T06:30:00Z"))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: schedule, since: first, now: second, calendar: zone).isEmpty)
        schedule.lastOnAttempt = first
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: schedule, since: since, now: second, calendar: zone).isEmpty)
    }

    func testOvernightTimesFollowLocalDaysAcrossBothDSTChanges() {
        let zone = calendar("America/New_York")
        let spring = schedule(date: "2026-03-07T12:00:00Z", weekdays: [7], on: 22 * 60, off: 6 * 60)
        let springEvents = SchedulePlanner.dueOccurrences(for: spring, since: date("2026-03-07T12:00:00Z"), now: date("2026-03-08T12:00:00Z"), calendar: zone)
        XCTAssertEqual(springEvents.map(\.date), [date("2026-03-08T03:00:00Z"), date("2026-03-08T10:00:00Z")])
        let fall = schedule(date: "2026-10-31T12:00:00Z", weekdays: [7], on: 22 * 60, off: 6 * 60)
        let fallEvents = SchedulePlanner.dueOccurrences(for: fall, since: date("2026-10-31T12:00:00Z"), now: date("2026-11-01T12:00:00Z"), calendar: zone)
        XCTAssertEqual(fallEvents.map(\.date), [date("2026-11-01T02:00:00Z"), date("2026-11-01T11:00:00Z")])
    }

    func testHalfHourDSTGapAlsoUsesNextValidTime() {
        let zone = calendar("Australia/Lord_Howe")
        let schedule = schedule(date: "2026-10-03T01:00:00Z", weekdays: [1], on: 2 * 60 + 15, off: nil)
        XCTAssertEqual(SchedulePlanner.nextOccurrence(for: schedule, after: date("2026-10-03T14:00:00Z"), calendar: zone)?.date, date("2026-10-03T15:30:00Z"))
    }

    func testMidnightDSTGapDoesNotShiftFollowingDaysOrDropFinalDay() {
        let zone = calendar("America/Sao_Paulo")
        let schedule = schedule(date: "2018-11-03T12:00:00Z", weekdays: Set(1...7), on: 15, off: nil)
        let due = SchedulePlanner.dueOccurrences(for: schedule, since: date("2018-11-04T02:00:00Z"), now: date("2018-11-05T02:15:00Z"), calendar: zone)
        XCTAssertEqual(due.map(\.date), [date("2018-11-04T03:00:00Z"), date("2018-11-05T02:15:00Z")])
    }

    func testSleepTimerUsesExactDeadlineIncludingSecondsAndIgnoresOffMinute() throws {
        let deadline = date("2026-11-01T06:30:27Z").addingTimeInterval(0.125)
        var timer = LightSchedule(name: "Sleep", deviceID: "light-1", channel: .background, purpose: .sleepTimer,
                                  date: deadline, offMinute: 5)
        try timer.validate()
        for zone in [calendar(), calendar("America/New_York"), calendar("Asia/Colombo")] {
            XCTAssertEqual(SchedulePlanner.nextOccurrence(for: timer, after: deadline.addingTimeInterval(-1), calendar: zone)?.date, deadline)
            XCTAssertEqual(SchedulePlanner.dueOccurrences(for: timer, since: deadline.addingTimeInterval(-1), now: deadline, calendar: zone).map(\.date), [deadline])
            XCTAssertNil(SchedulePlanner.nextOccurrence(for: timer, after: deadline, calendar: zone))
            XCTAssertTrue(SchedulePlanner.dueOccurrences(for: timer, since: deadline, now: deadline.addingTimeInterval(1), calendar: zone).isEmpty)
        }
        timer.lastOffAttempt = deadline
        XCTAssertNil(SchedulePlanner.nextOccurrence(for: timer, after: deadline.addingTimeInterval(-1), calendar: calendar()))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: timer, since: deadline.addingTimeInterval(-1), now: deadline, calendar: calendar()).isEmpty)
    }

    func testDisabledAndMalformedSchedulesNeverProduceEvents() {
        let since = date("2026-10-23T00:00:00Z"), now = date("2026-10-24T23:00:00Z")
        var disabled = schedule(); disabled.enabled = false
        var malformed = schedule(); malformed.weekdays = [0]
        for candidate in [disabled, malformed] {
            XCTAssertNil(SchedulePlanner.nextOccurrence(for: candidate, after: since, calendar: calendar()))
            XCTAssertTrue(SchedulePlanner.dueOccurrences(for: candidate, since: since, now: now, calendar: calendar()).isEmpty)
        }
        let valid = schedule()
        XCTAssertNil(SchedulePlanner.nextOccurrence(for: valid, after: Date(timeIntervalSinceReferenceDate: .nan), calendar: calendar()))
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: valid, since: now, now: since, calendar: calendar()).isEmpty)
        XCTAssertTrue(SchedulePlanner.dueOccurrences(for: valid, since: since, now: Date(timeIntervalSinceReferenceDate: .infinity), calendar: calendar()).isEmpty)
    }

    func testValidationRejectsInvalidNamesTimesWeekdaysDatesAndActionCombinations() throws {
        let valid = schedule(on: 0, off: 1439)
        try valid.validate()
        var longestName = valid; longestName.name = String(repeating: "L", count: 80)
        try longestName.validate()
        let changes: [(inout LightSchedule) -> Void] = [
            { $0.name = " \n " }, { $0.name = String(repeating: "L", count: 81) },
            { $0.deviceID = "" }, { $0.weekdays = [0] }, { $0.weekdays = [8] },
            { $0.onMinute = -1 }, { $0.offMinute = 1440 },
            { $0.onMinute = nil; $0.offMinute = nil }, { $0.offMinute = $0.onMinute },
            { $0.date = Date(timeIntervalSinceReferenceDate: .nan) },
            { $0.date = Date(timeIntervalSinceReferenceDate: .infinity) },
            { $0.lastOnAttempt = Date(timeIntervalSinceReferenceDate: -.infinity) },
            { $0.lastOffAttempt = Date(timeIntervalSinceReferenceDate: .nan) },
            { $0.presetID = "Relax"; $0.customProperties = ["bright": "50"] }
        ]
        for (index, change) in changes.enumerated() {
            var invalid = valid; change(&invalid)
            XCTAssertThrowsError(try invalid.validate(), "Invalid case \(index) must fail.")
        }
    }

    func testValidationRejectsMalformedNumericCustomStateOnEitherChannel() throws {
        let invalidProperties = [
            ["bright": "nan"], ["bg_bright": "inf"], ["ct": "-1"], ["bg_ct": "10001"],
            ["rgb": "16777216"], ["bg_rgb": "1e309"], ["hue": "361"], ["bg_sat": "101"],
            ["bright": ""], ["bg_ct": "4000.5"], ["bg_color_mode": "nan"], ["color_mode": "4"],
            ["rgb": "999999999999999999999999999"]
        ]
        for properties in invalidProperties {
            var invalid = schedule(); invalid.customProperties = properties
            XCTAssertThrowsError(try invalid.validate(), "Invalid properties: \(properties)")
        }
        var valid = schedule()
        valid.customProperties = ["bright": "50", "ct": "4000", "rgb": "0", "color_mode": "2", "bg_rgb": "16777215", "bg_bright": "75", "bg_color_mode": "1"]
        try valid.validate()
    }

    func testSleepTimerValidationRequiresOneShotOffOnly() throws {
        let timer = LightSchedule(deviceID: "light-1", purpose: .sleepTimer, offMinute: 0)
        try timer.validate()
        var repeating = timer; repeating.weekdays = [2]
        var turnsOn = timer; turnsOn.onMinute = 60
        var noOff = timer; noOff.offMinute = nil
        for invalid in [repeating, turnsOn, noOff] { XCTAssertThrowsError(try invalid.validate()) }
    }

    private func withStore(_ body: (ConfigurationStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("station-schedules-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ConfigurationStore(url: directory.appendingPathComponent("station.json")))
    }

    private func populatedConfiguration() -> StationConfiguration {
        var config = StationConfiguration()
        config.devices = [LightDevice(id: "light-1", name: "Desk", model: "lamp15", host: "192.0.2.1", properties: ["bg_bright": "42"])]
        config.assignments = ["light-1": DeviceAssignment(deviceID: "light-1", channel: .background, zone: 3)]
        config.savedScenes = [SavedScene(name: "Evening", actions: [SavedLightState(deviceID: "light-1", channel: .background, properties: ["bg_rgb": "255"])])]
        config.layoutID = "4"; config.displayID = 42; config.paletteID = "custom-palette"
        config.frameInterval = 0.35; config.syncBrightness = 63; config.sensitivity = 3.5; config.restoreOnStop = false
        return config
    }

    private func assertExistingSettings(_ actual: StationConfiguration, equal expected: StationConfiguration, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.version, expected.version, file: file, line: line)
        XCTAssertEqual(actual.devices, expected.devices, file: file, line: line)
        XCTAssertEqual(actual.assignments, expected.assignments, file: file, line: line)
        XCTAssertEqual(actual.savedScenes.first?.id, expected.savedScenes.first?.id, file: file, line: line)
        XCTAssertEqual(actual.savedScenes.first?.name, expected.savedScenes.first?.name, file: file, line: line)
        XCTAssertEqual(actual.savedScenes.first?.actions.first?.properties, expected.savedScenes.first?.actions.first?.properties, file: file, line: line)
        XCTAssertEqual(actual.layoutID, expected.layoutID, file: file, line: line)
        XCTAssertEqual(actual.displayID, expected.displayID, file: file, line: line)
        XCTAssertEqual(actual.paletteID, expected.paletteID, file: file, line: line)
        XCTAssertEqual(actual.frameInterval, expected.frameInterval, file: file, line: line)
        XCTAssertEqual(actual.syncBrightness, expected.syncBrightness, file: file, line: line)
        XCTAssertEqual(actual.sensitivity, expected.sensitivity, file: file, line: line)
        XCTAssertEqual(actual.restoreOnStop, expected.restoreOnStop, file: file, line: line)
    }

    func testConfigurationRoundTripRetainsSchedulesAndEveryExistingSetting() throws {
        try withStore { store in
            var config = populatedConfiguration()
            var saved = schedule(weekdays: [2, 4, 6])
            saved.customProperties = ["bg_bright": "42", "bg_rgb": "255"]
            saved.lastOnAttempt = date("2026-10-23T08:00:00Z")
            saved.lastOffAttempt = date("2026-10-23T18:00:00Z"); saved.lastResult = "Command acknowledged"
            config.schedules = [saved]
            try store.save(config)
            let loaded = try store.load()
            assertExistingSettings(loaded, equal: config)
            let restored = try XCTUnwrap(loaded.schedules.first)
            XCTAssertEqual(restored.id, saved.id); XCTAssertEqual(restored.name, saved.name)
            XCTAssertEqual(restored.deviceID, saved.deviceID); XCTAssertEqual(restored.channel, saved.channel)
            XCTAssertEqual(restored.enabled, saved.enabled); XCTAssertEqual(restored.purpose, saved.purpose)
            XCTAssertEqual(restored.date, saved.date); XCTAssertEqual(restored.weekdays, saved.weekdays)
            XCTAssertEqual(restored.onMinute, saved.onMinute); XCTAssertEqual(restored.offMinute, saved.offMinute)
            XCTAssertEqual(restored.customProperties, saved.customProperties); XCTAssertEqual(restored.presetID, saved.presetID)
            XCTAssertEqual(restored.lastOnAttempt, saved.lastOnAttempt); XCTAssertEqual(restored.lastOffAttempt, saved.lastOffAttempt)
            XCTAssertEqual(restored.lastResult, saved.lastResult)
        }
    }

    func testCompleteLegacyConfigurationWithoutSchedulesLoadsWithoutDroppingSettings() throws {
        try withStore { store in
            let config = populatedConfiguration()
            try store.save(config)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
            object.removeValue(forKey: "schedules")
            let legacy = try JSONSerialization.data(withJSONObject: object)
            try legacy.write(to: store.url)
            let loaded = try store.load()
            XCTAssertTrue(loaded.schedules.isEmpty)
            assertExistingSettings(loaded, equal: config)
            XCTAssertEqual(try Data(contentsOf: store.url), legacy)
            object.removeValue(forKey: "displayID")
            try JSONSerialization.data(withJSONObject: object).write(to: store.url)
            XCTAssertNil(try store.load().displayID)
        }
    }

    func testMissingOriginalRequiredFieldsRejectFileWithoutOverwriting() throws {
        try withStore { store in
            try store.save(populatedConfiguration())
            let complete = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
            for key in ["version", "devices", "assignments", "savedScenes", "layoutID", "paletteID", "frameInterval", "syncBrightness", "sensitivity", "restoreOnStop"] {
                var malformed = complete; malformed.removeValue(forKey: key)
                let before = try JSONSerialization.data(withJSONObject: malformed)
                try before.write(to: store.url)
                XCTAssertThrowsError(try store.load(), "Missing \(key) must remain invalid.")
                XCTAssertEqual(try Data(contentsOf: store.url), before)
            }
        }
    }

    func testConfigurationScheduleLimitDuplicateIDsAndValidationAreEnforcedOnlyOnLoad() throws {
        try withStore { store in
            var config = populatedConfiguration()
            config.schedules = (0..<256).map { _ in schedule(on: nil, off: 60) }
            try store.save(config)
            XCTAssertEqual(try store.load().schedules.count, 256)
            let valid = schedule()
            var invalid = valid; invalid.onMinute = -1
            for schedules in [config.schedules + [schedule()], [valid, valid], [invalid]] {
                config.schedules = schedules
                try store.save(config)
                let before = try Data(contentsOf: store.url)
                XCTAssertThrowsError(try store.load())
                XCTAssertEqual(try Data(contentsOf: store.url), before)
            }
            config.schedules = []; config.version = 999
            try store.save(config)
            let before = try Data(contentsOf: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.url), before)
        }
    }
}
