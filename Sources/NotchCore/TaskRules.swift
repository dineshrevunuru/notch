import Foundation

/// What the notch shows without hovering: counts, most urgent first.
nonisolated public struct TaskGlance: Equatable, Sendable {
    /// Reminders that have gone off and haven't been dealt with.
    public var ringing: Int
    public var overdue: Int
    public var dueToday: Int

    public static let empty = TaskGlance(ringing: 0, overdue: 0, dueToday: 0)
}

/// What the notch's left wing shows: the next thing coming.
nonisolated public enum UpNext: Equatable, Sendable {
    public enum Urgency: Equatable, Sendable { case normal, late, ringing }
    case task(TaskItem, urgency: Urgency)
    case meeting(TimedEvent)
}

/// One row of the open notch's agenda: a task or a meeting, in one time-ordered list.
nonisolated public enum AgendaItem: Equatable, Identifiable, Sendable {
    case task(TaskItem)
    case event(TimedEvent)

    public var id: String {
        switch self {
        case .task(let task): "task-\(task.id)"
        case .event(let event): "event-\(event.id)"
        }
    }
}

/// Pure rules over a list of tasks. No storage, no clock: everything is passed in.
nonisolated public enum TaskRules {
    // MARK: Time

    public static func isOverdue(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        guard !task.isDone, let due = task.due else { return false }
        if due.hasTime { return due.date <= now }
        return calendar.startOfDay(for: due.date) < calendar.startOfDay(for: now)
    }

    public static func isDueToday(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        guard !task.isDone, let due = task.due else { return false }
        return calendar.isDate(due.date, inSameDayAs: now) && !isOverdue(task, now: now, calendar: calendar)
    }

    public static func isRinging(_ task: TaskItem, now: Date) -> Bool {
        guard !task.isDone, !task.reminderHandled, let at = task.alertTime else { return false }
        return at <= now
    }

    /// "Today", "Tomorrow", "Mon", "Nov 30" (+ time when set), relative to `now`.
    public static func dueLabel(_ due: DueDate, now: Date, calendar: Calendar) -> String {
        let day: String
        if calendar.isDate(due.date, inSameDayAs: now) {
            day = due.hasTime ? "" : "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due.date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(due.date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due.date)).day ?? 0
            let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            day = (1...6).contains(days)
                ? due.date.formatted(style.weekday(.abbreviated))
                : due.date.formatted(style.month(.abbreviated).day())
        }
        guard due.hasTime else { return day }
        let time = TimeText.clock(due.date, calendar: calendar)
        return day.isEmpty ? time : "\(day) \(time)"
    }

    /// "2d late", "3h late", "20m late" for an overdue task.
    public static func lateness(_ due: DueDate, now: Date, calendar: Calendar) -> String {
        if due.hasTime {
            let seconds = now.timeIntervalSince(due.date)
            if seconds < 24 * 3600 { return "\(DurationText.short(seconds)) late" }
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due.date), to: calendar.startOfDay(for: now)).day ?? 0
        return "\(max(1, days))d late"
    }

    // MARK: Dependencies

    public static func openBlockers(of task: TaskItem, in index: [UUID: TaskItem]) -> [TaskItem] {
        task.blockedBy.compactMap { index[$0] }.filter { !$0.isDone }
    }

    public static func isBlocked(_ task: TaskItem, in index: [UUID: TaskItem]) -> Bool {
        !task.isDone && !openBlockers(of: task, in: index).isEmpty
    }

    /// True if making `task` wait on `dependency` would close a loop (including waiting on itself).
    public static func wouldCreateCycle(task: UUID, dependingOn dependency: UUID, in index: [UUID: TaskItem]) -> Bool {
        var stack = [dependency]
        var seen = Set<UUID>()
        while let id = stack.popLast() {
            if id == task { return true }
            guard seen.insert(id).inserted, let next = index[id] else { continue }
            stack.append(contentsOf: next.blockedBy)
        }
        return false
    }

    // MARK: Recurrence

    /// The next deadline for a repeating task: on schedule from the old deadline,
    /// skipping any occurrences that are already in the past.
    public static func nextDue(after due: DueDate, rule: Recurrence, now: Date, calendar: Calendar) -> DueDate {
        var next = due.date
        repeat {
            guard let advanced = calendar.date(byAdding: rule.component, value: rule.interval, to: next) else { break }
            next = advanced
        } while due.hasTime ? next <= now : calendar.startOfDay(for: next) < calendar.startOfDay(for: now)
        return DueDate(date: next, hasTime: due.hasTime)
    }

    // MARK: Views

    public static func glance(_ tasks: [TaskItem], now: Date, calendar: Calendar) -> TaskGlance {
        var glance = TaskGlance.empty
        for task in tasks where !task.isDone {
            if isRinging(task, now: now) { glance.ringing += 1 }
            if isOverdue(task, now: now, calendar: calendar) { glance.overdue += 1 }
            else if isDueToday(task, now: now, calendar: calendar) { glance.dueToday += 1 }
        }
        return glance
    }

    /// What needs you today: ringing reminders, then overdue (oldest first), then due today
    /// (timed ones by time, then by priority).
    public static func today(_ tasks: [TaskItem], now: Date, calendar: Calendar) -> [TaskItem] {
        func rank(_ t: TaskItem) -> Int {
            if isRinging(t, now: now) { return 0 }
            if isOverdue(t, now: now, calendar: calendar) { return 1 }
            return 2
        }
        return tasks
            .filter { !$0.isDone && (isRinging($0, now: now) || isOverdue($0, now: now, calendar: calendar) || isDueToday($0, now: now, calendar: calendar)) }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                // Within a group: timed deadlines before whole-day ones, then earliest first.
                let timedA = a.due?.hasTime ?? false, timedB = b.due?.hasTime ?? false
                if timedA != timedB { return timedA }
                if let da = a.due?.date, let db = b.due?.date, da != db { return da < db }
                if a.priority != b.priority { return a.priority > b.priority }
                return a.sortOrder < b.sortOrder
            }
    }

    /// The board: top-level cards (subtasks show as progress on their parent), optionally for one project.
    /// To Do and Doing keep your order; Done shows the last week, newest first.
    public static func board(_ tasks: [TaskItem], project: UUID?, now: Date, calendar: Calendar) -> [BoardColumn: [TaskItem]] {
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let cards = tasks.filter { $0.parentID == nil && (project == nil || $0.projectID == project) }
        func ordered(_ column: BoardColumn) -> [TaskItem] {
            cards.filter { $0.column == column }
                .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        }
        let done = cards
            .filter { ($0.completedAt ?? .distantPast) >= weekAgo }
            .sorted { ($0.completedAt ?? now) > ($1.completedAt ?? now) }
        return [.todo: ordered(.todo), .doing: ordered(.doing), .done: done]
    }

    /// Up next, in this order: a ringing reminder (it needs you now); otherwise whichever comes
    /// first in time, the next meeting today or the next timed task; then a late task; then the
    /// rest of today. Cards in Doing are "now", not "next", so they're skipped.
    public static func upNext(_ tasks: [TaskItem], events: [TimedEvent], now: Date, calendar: Calendar) -> UpNext? {
        let todo = today(tasks, now: now, calendar: calendar).filter { $0.status != .doing }
        if let ringing = todo.first(where: { isRinging($0, now: now) }) {
            return .task(ringing, urgency: .ringing)
        }
        let meeting = events
            .filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }
            .min { $0.start < $1.start }
        let timed = todo
            .filter { $0.due?.hasTime == true && !isOverdue($0, now: now, calendar: calendar) }
            .min { ($0.due?.date ?? .distantFuture) < ($1.due?.date ?? .distantFuture) }
        if let meeting, meeting.start <= (timed?.due?.date ?? .distantFuture) {
            return .meeting(meeting)
        }
        if let timed { return .task(timed, urgency: .normal) }
        if let late = todo.first(where: { isOverdue($0, now: now, calendar: calendar) }) {
            return .task(late, urgency: .late)
        }
        return todo.first.map { .task($0, urgency: .normal) }
    }

    /// Everything ahead of you, as one list: other cards in Doing, ringing reminders, late tasks,
    /// then today's meetings and timed tasks merged by time, then untimed tasks for today, then
    /// tomorrow's first meetings. `excluding` leaves out the task shown above the list as "now";
    /// a meeting you're in right now is left out too, for the same reason.
    public static func agenda(
        _ tasks: [TaskItem], events: [TimedEvent], now: Date, calendar: Calendar, excluding: UUID? = nil
    ) -> [AgendaItem] {
        let doing = tasks
            .filter { !$0.isDone && $0.status == .doing && $0.parentID == nil && $0.id != excluding }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let todo = today(tasks, now: now, calendar: calendar).filter { $0.status != .doing && $0.id != excluding }
        let ringing = todo.filter { isRinging($0, now: now) }
        let late = todo.filter { !isRinging($0, now: now) && isOverdue($0, now: now, calendar: calendar) }
        let rest = todo.filter { !isRinging($0, now: now) && !isOverdue($0, now: now, calendar: calendar) }

        let ahead = events.filter { $0.start > now }.sorted { $0.start < $1.start }
        let todayEvents = ahead.filter { calendar.isDate($0.start, inSameDayAs: now) }
        let tomorrowEvents = ahead.filter { !calendar.isDate($0.start, inSameDayAs: now) }.prefix(2)

        var timed: [(Date, AgendaItem)] = todayEvents.map { ($0.start, .event($0)) }
        timed += rest.compactMap { task in
            guard let due = task.due, due.hasTime else { return nil }
            return (due.date, .task(task))
        }
        timed.sort { $0.0 < $1.0 }
        let untimed = rest.filter { $0.due?.hasTime != true }

        return doing.map(AgendaItem.task) + ringing.map(AgendaItem.task) + late.map(AgendaItem.task)
            + timed.map(\.1) + untimed.map(AgendaItem.task) + tomorrowEvents.map(AgendaItem.event)
    }

    /// Open tasks due after today, grouped by day, soonest first.
    public static func upcoming(_ tasks: [TaskItem], now: Date, calendar: Calendar) -> [(day: Date, tasks: [TaskItem])] {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let future = tasks.filter { !$0.isDone && ($0.due?.date ?? .distantPast) >= startOfTomorrow }
        let grouped = Dictionary(grouping: future) { calendar.startOfDay(for: $0.due!.date) }
        return grouped.keys.sorted().map { day in
            (day, grouped[day]!.sorted { ($0.due!.date, -$0.priority.rawValue) < ($1.due!.date, -$1.priority.rawValue) })
        }
    }
}
