import Foundation

nonisolated public enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case none = 0, low, medium, high

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// "!", "!!", "!!!" — empty for none.
    public var marks: String { String(repeating: "!", count: rawValue) }
}

/// A deadline: a whole day, or a day and a time.
nonisolated public struct DueDate: Codable, Equatable, Sendable {
    /// For a day-only deadline, the start of that day.
    public var date: Date
    public var hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }

    public static func day(_ date: Date, calendar: Calendar = .current) -> DueDate {
        DueDate(date: calendar.startOfDay(for: date), hasTime: false)
    }
}

nonisolated public struct Recurrence: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case day, week, month, year
    }

    public var unit: Unit
    public var interval: Int

    public init(unit: Unit, interval: Int = 1) {
        self.unit = unit
        self.interval = max(1, interval)
    }

    /// "Daily", "Every 2 weeks".
    public var label: String {
        if interval == 1 {
            switch unit {
            case .day: return "Daily"
            case .week: return "Weekly"
            case .month: return "Monthly"
            case .year: return "Yearly"
            }
        }
        return "Every \(interval) \(unit.rawValue)s"
    }

    var component: Calendar.Component {
        switch unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

/// Where a task sits on the board. Done is not a status: it's `completedAt`, so finishing a task
/// anywhere (the notch, a checkbox, the board) means the same thing.
nonisolated public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo, doing
}

/// The board's three columns.
nonisolated public enum BoardColumn: String, CaseIterable, Identifiable, Sendable {
    case todo, doing, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "To Do"
        case .doing: "Doing"
        case .done: "Done"
        }
    }
}

nonisolated public struct Project: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var sortOrder: Double

    public init(id: UUID = UUID(), name: String, sortOrder: Double) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

nonisolated public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var notes: String
    /// nil means Inbox.
    public var projectID: UUID?
    /// Set when this is a subtask.
    public var parentID: UUID?
    public var priority: Priority
    public var tags: [String]
    public var due: DueDate?
    /// When to alert, as you set it. Repeating tasks carry it forward.
    public var reminder: Date?
    /// Set by Snooze; the alert rings at this time instead of `reminder`.
    public var snoozedUntil: Date?
    /// Set by Dismiss: the alert has been dealt with and stops ringing.
    public var reminderHandled: Bool
    public var recurrence: Recurrence?
    /// Tasks that have to be finished before this one can start.
    public var blockedBy: [UUID]
    public var status: TaskStatus
    /// Your guess at how long it takes, for the planner's time check.
    public var estimateMinutes: Int?
    /// When it last moved into Doing.
    public var startedAt: Date?
    public let createdAt: Date
    public var completedAt: Date?
    public var sortOrder: Double

    public var isDone: Bool { completedAt != nil }

    public var column: BoardColumn {
        if isDone { return .done }
        return status == .doing ? .doing : .todo
    }

    /// When the alert actually rings: the snooze time if snoozed, else the reminder.
    public var alertTime: Date? { snoozedUntil ?? reminder }

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        projectID: UUID? = nil,
        parentID: UUID? = nil,
        priority: Priority = .none,
        tags: [String] = [],
        due: DueDate? = nil,
        reminder: Date? = nil,
        snoozedUntil: Date? = nil,
        reminderHandled: Bool = false,
        recurrence: Recurrence? = nil,
        blockedBy: [UUID] = [],
        status: TaskStatus = .todo,
        estimateMinutes: Int? = nil,
        startedAt: Date? = nil,
        createdAt: Date,
        completedAt: Date? = nil,
        sortOrder: Double = 0
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.projectID = projectID
        self.parentID = parentID
        self.priority = priority
        self.tags = tags
        self.due = due
        self.reminder = reminder
        self.snoozedUntil = snoozedUntil
        self.reminderHandled = reminderHandled
        self.recurrence = recurrence
        self.blockedBy = blockedBy
        self.status = status
        self.estimateMinutes = estimateMinutes
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.sortOrder = sortOrder
    }

    // Lenient decoding: a hand-written or script-written entry only needs id, title and createdAt.
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, projectID, parentID, priority, tags, due, reminder, snoozedUntil, reminderHandled, recurrence, blockedBy, status, estimateMinutes, startedAt, createdAt, completedAt, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .none
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        due = try c.decodeIfPresent(DueDate.self, forKey: .due)
        reminder = try c.decodeIfPresent(Date.self, forKey: .reminder)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        reminderHandled = try c.decodeIfPresent(Bool.self, forKey: .reminderHandled) ?? false
        recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence)
        blockedBy = try c.decodeIfPresent([UUID].self, forKey: .blockedBy) ?? []
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .todo
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
    }
}

/// Tags are stored without "#", trimmed, and unique regardless of case.
nonisolated public enum Tags {
    public static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    /// "client, #deep work,  urgent" → ["client", "deep work", "urgent"]
    public static func parse(_ text: String) -> [String] {
        normalize(text.split(separator: ",").map(String.init))
    }
}
