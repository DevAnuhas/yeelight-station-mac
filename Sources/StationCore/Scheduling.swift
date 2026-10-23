import Foundation

public enum SchedulePurpose: String, Codable, Sendable {
    case schedule, sleepTimer
}

public enum ScheduleAction: String, Codable, Sendable {
    case on, off
}

public struct LightSchedule: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var deviceID: String
    public var channel: LightChannel
    public var enabled: Bool
    public var purpose: SchedulePurpose
    public var date: Date
    /// Calendar weekday numbers: Sunday is 1 and Saturday is 7. Empty means one-shot.
    public var weekdays: Set<Int>
    public var onMinute: Int?
    public var offMinute: Int?
    public var presetID: String?
    public var customProperties: [String: String]?
    /// Store the claimed occurrence date before sending its command, even if that command fails.
    public var lastOnAttempt: Date?
    public var lastOffAttempt: Date?
    public var lastResult: String?

    public init(
        id: UUID = UUID(), name: String = "Schedule", deviceID: String,
        channel: LightChannel = .main, enabled: Bool = true,
        purpose: SchedulePurpose = .schedule, date: Date = Date(),
        weekdays: Set<Int> = [], onMinute: Int? = nil, offMinute: Int? = nil,
        presetID: String? = nil, customProperties: [String: String]? = nil,
        lastOnAttempt: Date? = nil, lastOffAttempt: Date? = nil, lastResult: String? = nil
    ) {
        self.id = id; self.name = name; self.deviceID = deviceID; self.channel = channel
        self.enabled = enabled; self.purpose = purpose; self.date = date
        self.weekdays = weekdays; self.onMinute = onMinute; self.offMinute = offMinute
        self.presetID = presetID; self.customProperties = customProperties
        self.lastOnAttempt = lastOnAttempt; self.lastOffAttempt = lastOffAttempt
        self.lastResult = lastResult
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else {
            throw StationError.invalidResponse("Enter a schedule name of 1–80 characters.")
        }
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StationError.invalidResponse("Choose a light for the schedule.")
        }
        guard date.timeIntervalSinceReferenceDate.isFinite,
              lastOnAttempt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              lastOffAttempt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw StationError.invalidResponse("The schedule contains an invalid date.")
        }
        guard weekdays.allSatisfy({ (1...7).contains($0) }),
              onMinute.map({ (0...1439).contains($0) }) ?? true,
              offMinute.map({ (0...1439).contains($0) }) ?? true else {
            throw StationError.invalidResponse("Choose valid weekdays and times for the schedule.")
        }
        guard onMinute != nil || offMinute != nil else {
            throw StationError.invalidResponse("Enable at least one on or off action.")
        }
        if let onMinute, let offMinute, onMinute == offMinute {
            throw StationError.invalidResponse("Choose different on and off times.")
        }
        guard presetID == nil || customProperties == nil else {
            throw StationError.invalidResponse("Choose either a preset or a custom light state.")
        }
        if let properties = customProperties {
            guard LightProperties.validate(properties) else {
                throw StationError.invalidResponse("The scheduled light state contains invalid values.")
            }
            // Commands consume integers. Reject empty, fractional and overflowing values too.
            for prefix in ["", "bg_"] {
                for key in ["bright", "ct", "rgb", "hue", "sat", "color_mode"] {
                    guard let value = properties[prefix + key] else { continue }
                    guard let integer = Int(value), key != "color_mode" || (1...3).contains(integer) else {
                        throw StationError.invalidResponse("The scheduled light state contains an invalid \(prefix + key).")
                    }
                }
            }
        }
        if purpose == .sleepTimer {
            guard weekdays.isEmpty, onMinute == nil, offMinute != nil else {
                throw StationError.invalidResponse("A sleep timer must turn off once, without a repeating or on action.")
            }
        }
    }
}

public struct ScheduleOccurrence: Identifiable, Sendable {
    public let id: String
    public let scheduleID: UUID
    public let action: ScheduleAction
    public let date: Date

    public init(scheduleID: UUID, action: ScheduleAction, date: Date) {
        self.id = "\(scheduleID.uuidString):\(action.rawValue):\(date.timeIntervalSinceReferenceDate)"
        self.scheduleID = scheduleID; self.action = action; self.date = date
    }
}

public enum SchedulePlanner {
    public static func nextOccurrence(
        for schedule: LightSchedule, after: Date, calendar: Calendar = .current
    ) -> ScheduleOccurrence? {
        guard isUsable(schedule), after.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if schedule.purpose == .sleepTimer {
            return available(occurrence(for: schedule, action: .off, date: schedule.date), for: schedule, after: after)
        }
        guard let anchor = calendar.dateInterval(of: .day, for: schedule.date)?.start else { return nil }
        if schedule.weekdays.isEmpty {
            return occurrences(for: schedule, on: anchor, calendar: calendar)
                .filter { available($0, for: schedule, after: after) != nil }.sorted(by: ordered).first
        }

        var candidates: [ScheduleOccurrence] = []
        for action in [ScheduleAction.on, .off] {
            guard minute(for: action, in: schedule) != nil else { continue }
            let cutoff = max(after, lastAttempt(for: action, in: schedule) ?? after)
            guard var day = calendar.dateInterval(of: .day, for: cutoff)?.start else { continue }
            if action == .off, isOvernight(schedule), let previous = previousDay(before: day, calendar: calendar) {
                day = previous
            }
            day = max(day, anchor)
            // One selected weekday must occur within a week, including today's already-passed time.
            for _ in 0...7 {
                if let candidate = occurrences(for: schedule, on: day, calendar: calendar)
                    .first(where: { $0.action == action && available($0, for: schedule, after: after) != nil }) {
                    candidates.append(candidate)
                    break
                }
                guard let following = nextDay(after: day, calendar: calendar), following > day else { break }
                day = following
            }
        }
        return candidates.sorted(by: ordered).first
    }

    /// The caller supplies the active polling window; skipped time after sleep or quit must not be replayed.
    public static func dueOccurrences(
        for schedule: LightSchedule, since: Date, now: Date, calendar: Calendar = .current
    ) -> [ScheduleOccurrence] {
        guard isUsable(schedule), since.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, now > since else { return [] }
        if schedule.purpose == .sleepTimer {
            let event = occurrence(for: schedule, action: .off, date: schedule.date)
            return available(event, for: schedule, after: since) != nil && event.date <= now ? [event] : []
        }
        guard let anchor = calendar.dateInterval(of: .day, for: schedule.date)?.start else { return [] }
        if schedule.weekdays.isEmpty {
            return occurrences(for: schedule, on: anchor, calendar: calendar)
                .filter { available($0, for: schedule, after: since) != nil && $0.date <= now }.sorted(by: ordered)
        }
        guard var day = calendar.dateInterval(of: .day, for: since)?.start,
              let finalDay = calendar.dateInterval(of: .day, for: now)?.start else { return [] }
        if isOvernight(schedule), let previous = previousDay(before: day, calendar: calendar) { day = previous }
        day = max(day, anchor)
        var result: [ScheduleOccurrence] = []
        while day <= finalDay {
            result += occurrences(for: schedule, on: day, calendar: calendar)
                .filter { available($0, for: schedule, after: since) != nil && $0.date <= now }
            guard let following = nextDay(after: day, calendar: calendar), following > day else { break }
            day = following
        }
        return result.sorted(by: ordered)
    }

    private static func isUsable(_ schedule: LightSchedule) -> Bool {
        schedule.enabled && (try? schedule.validate()) != nil
    }

    private static func minute(for action: ScheduleAction, in schedule: LightSchedule) -> Int? {
        action == .on ? schedule.onMinute : schedule.offMinute
    }

    private static func lastAttempt(for action: ScheduleAction, in schedule: LightSchedule) -> Date? {
        action == .on ? schedule.lastOnAttempt : schedule.lastOffAttempt
    }

    private static func isOvernight(_ schedule: LightSchedule) -> Bool {
        guard let on = schedule.onMinute, let off = schedule.offMinute else { return false }
        return off <= on
    }

    private static func previousDay(before day: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .day, for: day.addingTimeInterval(-1))?.start
    }

    private static func nextDay(after day: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .day, for: day)?.end
    }

    private static func occurrence(for schedule: LightSchedule, action: ScheduleAction, date: Date) -> ScheduleOccurrence {
        ScheduleOccurrence(scheduleID: schedule.id, action: action, date: date)
    }

    private static func available(
        _ event: ScheduleOccurrence, for schedule: LightSchedule, after: Date
    ) -> ScheduleOccurrence? {
        guard event.date > after else { return nil }
        if let attempted = lastAttempt(for: event.action, in: schedule), event.date <= attempted { return nil }
        return event
    }

    private static func occurrences(for schedule: LightSchedule, on day: Date, calendar: Calendar) -> [ScheduleOccurrence] {
        guard schedule.weekdays.isEmpty || schedule.weekdays.contains(calendar.component(.weekday, from: day)) else { return [] }
        var result: [ScheduleOccurrence] = []
        for action in [ScheduleAction.on, .off] {
            guard let minute = minute(for: action, in: schedule) else { continue }
            var actionDay = day
            if action == .off, isOvernight(schedule) {
                guard let followingDay = nextDay(after: day, calendar: calendar) else { continue }
                actionDay = followingDay
            }
            guard let date = wallClockDate(minute: minute, on: actionDay, calendar: calendar) else { continue }
            result.append(occurrence(for: schedule, action: action, date: date))
        }
        return result
    }

    private static func wallClockDate(minute: Int, on day: Date, calendar: Calendar) -> Date? {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return nil }
        if let date = calendar.nextDate(
            after: interval.start.addingTimeInterval(-1),
            matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
        ), date >= interval.start, date < interval.end { return date }

        // Foundation can skip the day for partial-hour gaps (e.g. Lord Howe's 02:00–02:30).
        // Only that exceptional path scans the day's actual minutes for the first valid wall time.
        var candidate = interval.start
        while candidate < interval.end {
            let time = calendar.dateComponents([.hour, .minute], from: candidate)
            if let hour = time.hour, let actualMinute = time.minute, hour * 60 + actualMinute >= minute {
                return candidate
            }
            let following = candidate.addingTimeInterval(60)
            guard following > candidate else { break }
            candidate = following
        }
        return nil
    }

    private static func ordered(_ lhs: ScheduleOccurrence, _ rhs: ScheduleOccurrence) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.action == .on && rhs.action == .off
    }
}
