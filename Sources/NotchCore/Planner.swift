import Foundation

/// One day's plan: the tasks you picked in the morning, and how you closed the day.
nonisolated public struct DayPlan: Codable, Equatable, Identifiable, Sendable {
    /// "2026-11-19" in your time zone.
    public let day: String
    /// The picks, in the order you chose them. At most `Planner.maxPicks`.
    public var taskIDs: [UUID]
    public var plannedAt: Date
    public var closedAt: Date?
    /// "Tomorrow, start with…": written at wrap-up, shown at the top of the next plan.
    public var note: String

    public var id: String { day }
    public var isClosed: Bool { closedAt != nil }

    public init(day: String, taskIDs: [UUID], plannedAt: Date, closedAt: Date? = nil, note: String = "") {
        self.day = day
        self.taskIDs = taskIDs
        self.plannedAt = plannedAt
        self.closedAt = closedAt
        self.note = note
    }
}

/// A stretch of focus time, recorded when a focus round ends or is cut short.
nonisolated public struct FocusSession: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let taskID: UUID?

    public var minutes: Double { max(0, end.timeIntervalSince(start)) / 60 }

    public init(start: Date, end: Date, taskID: UUID?) {
        self.start = start
        self.end = end
        self.taskID = taskID
    }
}

/// Your working hours, used to work out how much of the day is actually free.
nonisolated public struct Workday: Equatable, Sendable {
    public var startHour: Int
    public var endHour: Int

    public init(startHour: Int = 9, endHour: Int = 18) {
        self.startHour = min(max(0, startHour), 23)
        self.endHour = min(max(self.startHour + 1, endHour), 24)
    }

    public var label: String {
        func hour(_ h: Int) -> String {
            let h12 = h % 12 == 0 ? 12 : h % 12
            return "\(h12) \(h < 12 || h == 24 ? "AM" : "PM")"
        }
        return "\(hour(startHour)) – \(hour(endHour))"
    }
}

/// How the planned work compares with the free time. The 20% buffer is the rule: no plan
/// fills 100% of the available time.
nonisolated public enum Capacity: Equatable, Sendable {
    /// Planned work fits inside 80% of the free time.
    case fits
    /// Past the 80% line: no breathing room left.
    case tight
    /// More work than free time.
    case over

    public static let buffer = 0.2

    public static func of(planned: Int, free: Int) -> Capacity {
        guard free > 0 else { return planned > 0 ? .over : .fits }
        let share = Double(planned) / Double(free)
        if share > 1 { return .over }
        if share > 1 - buffer { return .tight }
        return .fits
    }
}

nonisolated public enum Planner {
    public static let maxPicks = 3
    /// What a pick counts for when it has no estimate yet.
    public static let defaultEstimate = 30

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func isWorkday(_ date: Date, calendar: Calendar) -> Bool {
        !calendar.isDateInWeekend(date)
    }

    /// Minutes of workday left from `now`, and how many of them meetings take. Overlapping
    /// meetings count once.
    public static func time(on now: Date, workday: Workday, events: [TimedEvent], calendar: Calendar) -> (free: Int, meetings: Int) {
        let dayStart = calendar.startOfDay(for: now)
        guard let open = calendar.date(byAdding: .hour, value: workday.startHour, to: dayStart),
              let close = calendar.date(byAdding: .hour, value: workday.endHour, to: dayStart) else { return (0, 0) }
        let from = max(open, now)
        guard close > from else { return (0, 0) }

        let clipped = events
            .map { (max($0.start, from), min($0.end, close)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for interval in clipped {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else {
                merged.append(interval)
            }
        }
        let meetingSeconds = merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        let total = close.timeIntervalSince(from)
        return (Int((total - meetingSeconds) / 60), Int(meetingSeconds / 60))
    }

    /// Tasks yesterday left behind: overdue ones, and cards that sat in Doing from an earlier day.
    public static func carryOver(_ tasks: [TaskItem], now: Date, calendar: Calendar) -> [TaskItem] {
        let today = calendar.startOfDay(for: now)
        return tasks
            .filter { task in
                guard !task.isDone, task.parentID == nil else { return false }
                if TaskRules.isOverdue(task, now: now, calendar: calendar) { return true }
                if task.status == .doing, let started = task.startedAt, started < today { return true }
                return false
            }
            .sorted { ($0.due?.date ?? .distantFuture) < ($1.due?.date ?? .distantFuture) }
    }

    /// What's worth picking today, best first: ringing, due today, in Doing, then by priority and age.
    public static func candidates(_ tasks: [TaskItem], now: Date, calendar: Calendar, limit: Int = 12) -> [TaskItem] {
        func score(_ t: TaskItem) -> Int {
            var s = t.priority.rawValue * 10
            if TaskRules.isRinging(t, now: now) { s += 100 }
            if TaskRules.isOverdue(t, now: now, calendar: calendar) { s += 80 }
            if TaskRules.isDueToday(t, now: now, calendar: calendar) { s += 60 }
            if t.status == .doing { s += 40 }
            if let due = t.due, due.date < (calendar.date(byAdding: .day, value: 3, to: now) ?? now) { s += 20 }
            return s
        }
        let index = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return tasks
            .filter { !$0.isDone && $0.parentID == nil && !TaskRules.isBlocked($0, in: index) }
            .sorted { a, b in
                let sa = score(a), sb = score(b)
                return sa != sb ? sa > sb : a.createdAt < b.createdAt
            }
            .prefix(limit)
            .map { $0 }
    }

    public static func plannedMinutes(_ picks: [TaskItem]) -> Int {
        picks.reduce(0) { $0 + ($1.estimateMinutes ?? defaultEstimate) }
    }

    /// Whether the notch should prompt now. Weekdays only; once each per day (the caller tracks
    /// what it has shown). Plan from the start of the workday until an hour before its end;
    /// wrap up from the end, if the day was planned and isn't closed.
    public static func prompt(now: Date, workday: Workday, plan: DayPlan?, calendar: Calendar) -> NotchAlert? {
        guard isWorkday(now, calendar: calendar) else { return nil }
        let hour = calendar.component(.hour, from: now)
        let day = dayKey(now, calendar: calendar)
        if plan == nil, hour >= workday.startHour, hour < workday.endHour - 1 {
            return .planDay(day: day)
        }
        if let plan, !plan.isClosed, hour >= workday.endHour {
            return .wrapUpDay(day: day)
        }
        return nil
    }
}
