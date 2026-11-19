import Foundation

/// A calendar event reduced to what the notch needs. All-day, cancelled and
/// declined events are filtered out before they become a `TimedEvent`.
nonisolated public struct TimedEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(id: String, title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

/// The one-line answer to "what is my day doing right now?"
nonisolated public struct DayStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case busy   // inside an event, or one is starting this minute
        case free   // a gap before the next event today
        case clear  // nothing else today
    }

    public let kind: Kind
    public let headline: String
    public let detail: String?
}

nonisolated public enum StatusEngine {
    /// The event you're in. When events overlap, the one ending first is the one to watch.
    public static func current(at now: Date, events: [TimedEvent]) -> TimedEvent? {
        events.filter { $0.start <= now && now < $0.end }.min { $0.end < $1.end }
    }

    /// Status for `now`. `events` may be unsorted. The Upcoming list sits right below the
    /// status, so the status never repeats what the list already shows.
    public static func status(at now: Date, events: [TimedEvent], calendar: Calendar) -> DayStatus {
        if let current = current(at: now, events: events) {
            let left = DurationText.short(current.end.timeIntervalSince(now))
            return DayStatus(
                kind: .busy,
                headline: "In \(current.title)",
                detail: "Until \(TimeText.clock(current.end, calendar: calendar)) · \(left) left"
            )
        }

        let next = events.filter { $0.start > now }.min { $0.start < $1.start }
        guard let next, calendar.isDate(next.start, inSameDayAs: now) else {
            return DayStatus(kind: .clear, headline: "Clear for the rest of today", detail: nil)
        }

        let gap = next.start.timeIntervalSince(now)
        if gap < 60 {
            return DayStatus(kind: .busy, headline: "\(next.title) is starting", detail: nil)
        }
        return DayStatus(kind: .free, headline: "Free for \(DurationText.short(gap))", detail: nil)
    }

    /// Events that have not ended yet, soonest first — minus the one the status line is already about.
    public static func upcoming(at now: Date, events: [TimedEvent], limit: Int) -> [TimedEvent] {
        let headline = current(at: now, events: events)?.id
        return Array(events
            .filter { $0.end > now && $0.id != headline }
            .sorted { $0.start < $1.start }
            .prefix(limit))
    }

    /// The next event if it starts within `window` seconds. Drives the cue beside the notch.
    public static func startingSoon(at now: Date, events: [TimedEvent], within window: TimeInterval = 10 * 60) -> TimedEvent? {
        events
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= window }
            .min { $0.start < $1.start }
    }

    /// Left-column label in the Upcoming list: "Now", "2:30 PM", or "Thu 9:00 AM".
    public static func timeLabel(for event: TimedEvent, at now: Date, calendar: Calendar) -> String {
        if event.start <= now { return "Now" }
        if calendar.isDate(event.start, inSameDayAs: now) { return TimeText.clock(event.start, calendar: calendar) }
        return TimeText.weekdayClock(event.start, calendar: calendar)
    }
}

nonisolated public enum DurationText {
    /// "45m", "2h", "1h 40m". Rounds up to the minute so a countdown never reads "0m".
    public static func short(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// Focus countdown: "24:05", or "1:02:00" past an hour.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

nonisolated public enum TimeText {
    public static func clock(_ date: Date, calendar: Calendar) -> String {
        date.formatted(style(calendar).hour().minute())
    }

    /// "5 PM" on the hour, "4:15 PM" otherwise: the short form for tight spaces like the notch wings.
    public static func compactClock(_ date: Date, calendar: Calendar) -> String {
        calendar.component(.minute, from: date) == 0
            ? date.formatted(style(calendar).hour())
            : clock(date, calendar: calendar)
    }

    public static func weekdayClock(_ date: Date, calendar: Calendar) -> String {
        date.formatted(style(calendar).weekday(.abbreviated).hour().minute())
    }

    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }
}
