import Foundation

/// A banner that drops down from the notch on its own.
nonisolated public enum NotchAlert: Equatable, Identifiable, Sendable {
    case reminder(taskID: UUID, title: String, at: Date)
    /// Several reminders at once (say, after the Mac wakes): one banner instead of a queue.
    case reminders(count: Int)
    case due(taskID: UUID, title: String, at: Date)
    case eventSoon(eventID: String, title: String, start: Date)
    /// A focus round ended and its break started.
    case focusEnded(round: Int, rounds: Int, breakMinutes: Int, isLongBreak: Bool, at: Date)
    /// A break ended; the next round is waiting to be started.
    case breakEnded(nextRound: Int, rounds: Int, at: Date)
    /// The workday started and today has no plan yet.
    case planDay(day: String)
    /// The workday ended and today's plan is still open.
    case wrapUpDay(day: String)
    /// A distraction has run long: a game, video, or a feed.
    case nudge(Nudge, at: Date)

    public var id: String {
        switch self {
        case .reminder(let task, _, let at): "reminder-\(task)-\(Int(at.timeIntervalSince1970))"
        case .reminders(let count): "reminders-\(count)"
        case .due(let task, _, let at): "due-\(task)-\(Int(at.timeIntervalSince1970))"
        case .eventSoon(let event, _, let start): "event-\(event)-\(Int(start.timeIntervalSince1970))"
        case .focusEnded(_, _, _, _, let at): "focus-ended-\(Int(at.timeIntervalSince1970))"
        case .breakEnded(_, _, let at): "break-ended-\(Int(at.timeIntervalSince1970))"
        case .planDay(let day): "plan-\(day)"
        case .wrapUpDay(let day): "wrap-up-\(day)"
        case .nudge(_, let at): "nudge-\(Int(at.timeIntervalSince1970))"
        }
    }

    public var taskID: UUID? {
        switch self {
        case .reminder(let id, _, _), .due(let id, _, _): id
        default: nil
        }
    }

    /// Seconds on screen before it tucks back, unless the pointer is resting on it.
    /// Anything unhandled stays visible afterwards as a count beside the camera.
    public var lingers: TimeInterval {
        switch self {
        case .reminder, .reminders, .breakEnded: 9
        case .planDay, .wrapUpDay: 12
        case .nudge: 10
        case .due, .eventSoon, .focusEnded: 6
        }
    }
}

nonisolated public enum AlertPlanner {
    /// Focus mode holds task banners until the break. Meetings and the timer's own banners
    /// still come through: missing a meeting costs more than an interruption.
    public static func isHeldDuringFocus(_ alert: NotchAlert) -> Bool {
        switch alert {
        case .reminder, .reminders, .due, .planDay, .wrapUpDay: true
        // A nudge during focus is the whole point, so it's never held.
        case .eventSoon, .focusEnded, .breakEnded, .nudge: false
        }
    }

    /// How long before an event its banner drops.
    public static let eventLead: TimeInterval = 5 * 60
    /// A deadline only gets a banner as it arrives, not when the app relaunches long after.
    public static let dueFreshness: TimeInterval = 2 * 60
    /// More reminders than this at once are folded into one banner.
    public static let batchThreshold = 2

    /// Alerts that should drop now and haven't been shown. `consumed` holds every id these cover,
    /// including individual reminders folded into a batch, so the caller can mark them seen.
    public static func plan(
        now: Date,
        tasks: [TaskItem],
        events: [TimedEvent],
        seen: Set<String>
    ) -> (alerts: [NotchAlert], consumed: Set<String>) {
        var consumed = Set<String>()

        let reminders: [NotchAlert] = tasks
            .filter { TaskRules.isRinging($0, now: now) }
            .sorted { ($0.alertTime ?? now) < ($1.alertTime ?? now) }
            .compactMap { task in
                guard let at = task.alertTime else { return nil }
                return .reminder(taskID: task.id, title: task.title, at: at)
            }
            .filter { !seen.contains($0.id) }

        var alerts: [NotchAlert] = []
        if reminders.count > batchThreshold {
            alerts.append(.reminders(count: reminders.count))
            consumed.formUnion(reminders.map(\.id))
        } else {
            alerts.append(contentsOf: reminders)
        }

        let ringingIDs = Set(tasks.filter { TaskRules.isRinging($0, now: now) }.map(\.id))
        for task in tasks where !task.isDone && !ringingIDs.contains(task.id) {
            guard let due = task.due, due.hasTime else { continue }
            let since = now.timeIntervalSince(due.date)
            guard since >= 0, since < dueFreshness else { continue }
            let alert = NotchAlert.due(taskID: task.id, title: task.title, at: due.date)
            if !seen.contains(alert.id) { alerts.append(alert) }
        }

        for event in events {
            let lead = event.start.timeIntervalSince(now)
            guard lead > 0, lead <= eventLead else { continue }
            let alert = NotchAlert.eventSoon(eventID: event.id, title: event.title, start: event.start)
            if !seen.contains(alert.id) { alerts.append(alert) }
        }

        consumed.formUnion(alerts.map(\.id))
        return (alerts, consumed)
    }
}
