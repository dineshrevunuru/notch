import Foundation
import Observation

/// Every task and project, saved as one JSON file in Application Support.
/// The notch and the task window share one instance. You or a script can edit the file
/// by hand; the store picks up outside changes the next time it looks.
@Observable
public final class TaskStore {
    public static let maxTitleLength = 300

    public private(set) var projects: [Project] = []
    public private(set) var tasks: [TaskItem] = []
    public private(set) var days: [DayPlan] = []
    public private(set) var focusLog: [FocusSession] = []
    public private(set) var distractionLog: [DistractionSpan] = []
    /// Set when the file could not be read or written. Shown in the UI, never swallowed.
    public private(set) var lastError: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var lastKnownModification: Date?

    public init(fileURL: URL = TaskStore.defaultFileURL, legacyFileURL: URL? = TaskStore.legacyFileURL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            load()
        } else if let legacyFileURL {
            migrate(from: legacyFileURL)
        }
    }

    public static var defaultFileURL: URL { supportDirectory.appendingPathComponent("store.json") }
    /// The first version's flat list.
    public static var legacyFileURL: URL { supportDirectory.appendingPathComponent("tasks.json") }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch", isDirectory: true)
    }

    // MARK: Lookup

    public var index: [UUID: TaskItem] { Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }) }

    public func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func children(of id: UUID) -> [TaskItem] {
        tasks.filter { $0.parentID == id }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Done / total for a task's direct subtasks, or nil when it has none.
    public func subtaskProgress(of id: UUID) -> (done: Int, total: Int)? {
        let kids = children(of: id)
        guard !kids.isEmpty else { return nil }
        return (kids.filter(\.isDone).count, kids.count)
    }

    public func openBlockers(of id: UUID) -> [TaskItem] {
        guard let task = task(id) else { return [] }
        return TaskRules.openBlockers(of: task, in: index)
    }

    public func isBlocked(_ id: UUID) -> Bool {
        guard let task = task(id) else { return false }
        return TaskRules.isBlocked(task, in: index)
    }

    /// Tasks waiting on this one.
    public func dependents(of id: UUID) -> [TaskItem] {
        tasks.filter { $0.blockedBy.contains(id) }
    }

    public var allTags: [String] {
        Tags.normalize(tasks.filter { !$0.isDone }.flatMap(\.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public var sortedProjects: [Project] { projects.sorted { $0.sortOrder < $1.sortOrder } }

    // MARK: Tasks

    /// Adds a task. A subtask takes its parent's project.
    @discardableResult
    public func add(
        _ rawTitle: String,
        project: UUID? = nil,
        parent: UUID? = nil,
        due: DueDate? = nil,
        now: Date = .now
    ) -> TaskItem? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let projectID = parent.flatMap { task($0)?.projectID } ?? project
        let siblings = tasks.filter { $0.parentID == parent && $0.projectID == projectID }
        let item = TaskItem(
            title: String(title.prefix(Self.maxTitleLength)),
            projectID: projectID,
            parentID: parent,
            due: due,
            createdAt: now,
            sortOrder: (siblings.map(\.sortOrder).max() ?? 0) + 1
        )
        tasks.append(item)
        scheduleSave()
        return item
    }

    /// Replaces a task with an edited copy. Moving a task to another project moves its subtasks too.
    public func update(_ edited: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == edited.id }) else { return }
        var clean = edited
        clean.title = String(clean.title.prefix(Self.maxTitleLength))
        clean.tags = Tags.normalize(clean.tags)
        clean.blockedBy = clean.blockedBy.filter { $0 != clean.id }
        let movedProject = tasks[i].projectID != clean.projectID
        if tasks[i].reminder != clean.reminder {
            // A new reminder time starts fresh.
            clean.snoozedUntil = nil
            clean.reminderHandled = false
        }
        tasks[i] = clean
        if movedProject {
            for d in descendants(of: clean.id) {
                if let j = tasks.firstIndex(where: { $0.id == d }) { tasks[j].projectID = clean.projectID }
            }
        }
        scheduleSave()
    }

    public func toggle(_ id: UUID, now: Date = .now) {
        guard let task = task(id) else { return }
        if task.isDone { reopen(id) } else { complete(id, now: now) }
    }

    /// Finishes a task and its open subtasks. A repeating task schedules its next occurrence,
    /// subtasks included, fresh.
    public func complete(_ id: UUID, now: Date = .now, calendar: Calendar = .current) {
        guard let original = task(id), !original.isDone else { return }
        for target in [id] + descendants(of: id) {
            if let i = tasks.firstIndex(where: { $0.id == target }), tasks[i].completedAt == nil {
                tasks[i].completedAt = now
            }
        }
        if let rule = original.recurrence {
            scheduleNext(of: original, rule: rule, now: now, calendar: calendar)
        }
        scheduleSave()
    }

    public func reopen(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].completedAt = nil
        tasks[i].status = .todo
        scheduleSave()
    }

    // MARK: Board

    /// How many cards Doing holds before the board says it's too much at once.
    public static let doingLimit = 3

    /// Moves a card to a column, placed just before `before` (or at the end of the column).
    /// Done finishes the task (subtasks and repeats included); leaving Done reopens it.
    public func move(_ id: UUID, to column: BoardColumn, before target: UUID? = nil, in visible: [TaskItem] = [], now: Date = .now) {
        guard let current = task(id) else { return }
        switch column {
        case .done:
            if !current.isDone { complete(id, now: now) }
        case .todo, .doing:
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            if tasks[i].isDone { tasks[i].completedAt = nil }
            let status: TaskStatus = column == .doing ? .doing : .todo
            if status == .doing, tasks[i].status != .doing { tasks[i].startedAt = now }
            tasks[i].status = status
        }
        if let order = Self.sortOrder(placing: id, before: target, among: visible.filter { $0.id != id }),
           let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].sortOrder = order
        }
        scheduleSave()
    }

    /// A sort order that lands between the card above `target` and `target` itself.
    static func sortOrder(placing id: UUID, before target: UUID?, among column: [TaskItem]) -> Double? {
        let ordered = column.sorted { $0.sortOrder < $1.sortOrder }
        guard let target, let index = ordered.firstIndex(where: { $0.id == target }) else {
            return ordered.isEmpty ? nil : (ordered.last!.sortOrder + 1)
        }
        let below = ordered[index].sortOrder
        let above = index > 0 ? ordered[index - 1].sortOrder : below - 2
        return (above + below) / 2
    }

    /// Deletes a task and its subtasks, and frees anything that was waiting on them.
    public func delete(_ id: UUID) {
        let removed = Set([id] + descendants(of: id))
        tasks.removeAll { removed.contains($0.id) }
        for i in tasks.indices where tasks[i].blockedBy.contains(where: removed.contains) {
            tasks[i].blockedBy.removeAll(where: removed.contains)
        }
        scheduleSave()
    }

    /// Makes `id` wait on `dependency`. Returns false (and changes nothing) if that would make a loop.
    @discardableResult
    public func addDependency(_ id: UUID, blockedBy dependency: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), task(dependency) != nil,
              !TaskRules.wouldCreateCycle(task: id, dependingOn: dependency, in: index) else { return false }
        if !tasks[i].blockedBy.contains(dependency) {
            tasks[i].blockedBy.append(dependency)
            scheduleSave()
        }
        return true
    }

    public func removeDependency(_ id: UUID, blockedBy dependency: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].blockedBy.removeAll { $0 == dependency }
        scheduleSave()
    }

    /// Tasks `id` could wait on without making a loop: open, not itself, not its own subtasks.
    public func dependencyCandidates(for id: UUID) -> [TaskItem] {
        let own = Set([id] + descendants(of: id))
        let current = Set(task(id)?.blockedBy ?? [])
        let idx = index
        return tasks
            .filter { !$0.isDone && !own.contains($0.id) && !current.contains($0.id) }
            .filter { !TaskRules.wouldCreateCycle(task: id, dependingOn: $0.id, in: idx) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Rings again in `minutes`. Works for a reminder or for a deadline that just arrived.
    public func snoozeReminder(_ id: UUID, minutes: Int = 10, now: Date = .now) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].snoozedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
        tasks[i].reminderHandled = false
        scheduleSave()
    }

    /// Stops a ringing reminder without finishing the task. The reminder time itself is kept.
    public func dismissReminder(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].reminderHandled = true
        scheduleSave()
    }

    // MARK: Planner

    public func plan(for day: String) -> DayPlan? {
        days.first { $0.day == day }
    }

    /// The most recent closed day before `day`, for its "tomorrow, start with" note.
    public func previousPlan(before day: String) -> DayPlan? {
        days.filter { $0.day < day }.max { $0.day < $1.day }
    }

    /// Saves the morning's picks and puts them in Doing; anything else left in Doing goes back to To Do,
    /// so the board and the notch show exactly today's plan.
    public func savePlan(day: String, picks: [UUID], now: Date = .now) {
        let chosen = Array(picks.prefix(Planner.maxPicks))
        for i in tasks.indices where tasks[i].status == .doing && !tasks[i].isDone && !chosen.contains(tasks[i].id) {
            tasks[i].status = .todo
        }
        for id in chosen where task(id)?.status != .doing {
            move(id, to: .doing, now: now)
        }
        if let i = days.firstIndex(where: { $0.day == day }) {
            days[i].taskIDs = chosen
            days[i].plannedAt = now
            days[i].closedAt = nil
        } else {
            days.append(DayPlan(day: day, taskIDs: chosen, plannedAt: now))
        }
        scheduleSave()
    }

    public func closeDay(_ day: String, note: String, now: Date = .now) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = days.firstIndex(where: { $0.day == day }) {
            days[i].closedAt = now
            days[i].note = clean
        } else {
            days.append(DayPlan(day: day, taskIDs: [], plannedAt: now, closedAt: now, note: clean))
        }
        scheduleSave()
    }

    /// Moves a task's deadline to another day, keeping its time of day if it had one.
    public func reschedule(_ id: UUID, to day: Date, calendar: Calendar = .current) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let due = tasks[i].due, due.hasTime {
            let time = calendar.dateComponents([.hour, .minute], from: due.date)
            let moved = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
            tasks[i].due = DueDate(date: moved, hasTime: true)
        } else {
            tasks[i].due = .day(day, calendar: calendar)
        }
        if tasks[i].status == .doing { tasks[i].status = .todo }
        scheduleSave()
    }

    /// Carry-over's "Keep": an overdue task becomes due today; a card left in Doing counts as started today.
    public func keepForToday(_ id: UUID, now: Date = .now, calendar: Calendar = .current) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        // A missed time is gone; what's left is "today".
        if TaskRules.isOverdue(tasks[i], now: now, calendar: calendar) {
            tasks[i].due = .day(now, calendar: calendar)
        }
        if tasks[i].status == .doing { tasks[i].startedAt = now }
        scheduleSave()
    }

    /// Takes a task off the schedule: no deadline, back in To Do.
    public func unschedule(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].due = nil
        tasks[i].status = .todo
        scheduleSave()
    }

    public func setEstimate(_ id: UUID, minutes: Int?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].estimateMinutes = minutes
        scheduleSave()
    }

    /// Records focus time. Anything under a minute isn't worth a line.
    public func logFocus(start: Date, end: Date, task: UUID?) {
        let session = FocusSession(start: start, end: end, taskID: task)
        guard session.minutes >= 1 else { return }
        focusLog.append(session)
        scheduleSave()
    }

    public func focusMinutes(on day: Date, calendar: Calendar = .current) -> Int {
        Int(focusLog.filter { calendar.isDate($0.end, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes })
    }

    /// Records time on a distraction. Under a minute isn't worth a line.
    public func logDistraction(_ source: DistractionSource, start: Date, end: Date) {
        let span = DistractionSpan(name: source.name, kind: source.kind, start: start, end: end)
        guard span.minutes >= 1 else { return }
        distractionLog.append(span)
        scheduleSave()
    }

    /// Minutes per distraction on a day, most first.
    public func distractionMinutes(on day: Date, calendar: Calendar = .current) -> [(name: String, minutes: Int)] {
        var totals: [String: Double] = [:]
        for span in distractionLog where calendar.isDate(span.end, inSameDayAs: day) {
            totals[span.name, default: 0] += span.minutes
        }
        return totals.map { ($0.key, Int($0.value)) }.filter { $0.minutes > 0 }.sorted { $0.minutes > $1.minutes }
    }

    public func focusMinutes(for task: UUID) -> Int {
        Int(focusLog.filter { $0.taskID == task }.reduce(0) { $0 + $1.minutes })
    }

    // MARK: Projects

    @discardableResult
    public func addProject(_ rawName: String) -> Project? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let project = Project(name: name, sortOrder: (projects.map(\.sortOrder).max() ?? 0) + 1)
        projects.append(project)
        scheduleSave()
        return project
    }

    public func renameProject(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
        scheduleSave()
    }

    /// Removes a project. Its tasks move to the Inbox; nothing is deleted with it.
    public func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for i in tasks.indices where tasks[i].projectID == id { tasks[i].projectID = nil }
        scheduleSave()
    }

    public func project(named name: String) -> Project? {
        projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Persistence

    /// Writes immediately. Edits are otherwise batched for a moment so typing doesn't hit the disk per key.
    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        write()
    }

    /// Picks up changes another program made to the file. Skipped while an edit of ours is unsaved.
    public func reloadIfChangedOnDisk() {
        guard pendingSave == nil, let modified = modificationDate(), modified != lastKnownModification else { return }
        load()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.pendingSave = nil
            self.write()
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = StoreFile(version: StoreFile.currentVersion, projects: projects, tasks: tasks, days: days, focusLog: focusLog, distractionLog: distractionLog)
            try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
            lastKnownModification = modificationDate()
            lastError = nil
        } catch {
            lastError = "Couldn't save your tasks: \(error.localizedDescription)"
        }
    }

    private func load() {
        do {
            let file = try Self.decoder.decode(StoreFile.self, from: Data(contentsOf: fileURL))
            projects = file.projects
            tasks = file.tasks
            days = file.days
            focusLog = file.focusLog
            distractionLog = file.distractionLog
            lastKnownModification = modificationDate()
            lastError = nil
        } catch {
            // Keep the unreadable file instead of overwriting it on the next save.
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            lastError = "Couldn't read your tasks. The file was kept as \(backup.lastPathComponent)."
        }
    }

    /// Brings the first version's flat list across as Inbox tasks, then sets the old file aside.
    private func migrate(from legacy: URL) {
        guard let data = try? Data(contentsOf: legacy) else { return }
        do {
            let old = try Self.decoder.decode([LegacyTask].self, from: data)
            tasks = old.enumerated().map { offset, task in
                TaskItem(id: task.id, title: task.title, createdAt: task.createdAt, completedAt: task.completedAt, sortOrder: Double(offset + 1))
            }
            write()
            try? FileManager.default.moveItem(at: legacy, to: legacy.deletingPathExtension().appendingPathExtension("v1-migrated.json"))
        } catch {
            lastError = "Couldn't bring over your earlier list. It's still at \(legacy.lastPathComponent)."
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    // MARK: Helpers

    private func descendants(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var frontier = [id]
        while let next = frontier.popLast() {
            let kids = tasks.filter { $0.parentID == next }.map(\.id)
            result.append(contentsOf: kids)
            frontier.append(contentsOf: kids)
        }
        return result
    }

    private func scheduleNext(of original: TaskItem, rule: Recurrence, now: Date, calendar: Calendar) {
        let base = original.due ?? .day(now, calendar: calendar)
        let nextDue = TaskRules.nextDue(after: base, rule: rule, now: now, calendar: calendar)
        let shift = nextDue.date.timeIntervalSince(base.date)

        let next = TaskItem(
            title: original.title,
            notes: original.notes,
            projectID: original.projectID,
            parentID: original.parentID,
            priority: original.priority,
            tags: original.tags,
            due: nextDue,
            reminder: original.reminder.map { $0.addingTimeInterval(shift) },
            recurrence: rule,
            blockedBy: original.blockedBy,
            createdAt: now,
            sortOrder: original.sortOrder
        )
        tasks.append(next)

        for child in children(of: original.id) {
            tasks.append(TaskItem(
                title: child.title, notes: child.notes, projectID: child.projectID, parentID: next.id,
                priority: child.priority, tags: child.tags, createdAt: now, sortOrder: child.sortOrder
            ))
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

nonisolated struct StoreFile: Codable {
    static let currentVersion = 3
    var version: Int
    var projects: [Project]
    var tasks: [TaskItem]
    var days: [DayPlan]
    var focusLog: [FocusSession]
    var distractionLog: [DistractionSpan]

    init(version: Int, projects: [Project], tasks: [TaskItem], days: [DayPlan], focusLog: [FocusSession], distractionLog: [DistractionSpan]) {
        self.version = version
        self.projects = projects
        self.tasks = tasks
        self.days = days
        self.focusLog = focusLog
        self.distractionLog = distractionLog
    }

    // Version 2 files have no days or focus log; read them as empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        days = try c.decodeIfPresent([DayPlan].self, forKey: .days) ?? []
        focusLog = try c.decodeIfPresent([FocusSession].self, forKey: .focusLog) ?? []
        distractionLog = try c.decodeIfPresent([DistractionSpan].self, forKey: .distractionLog) ?? []
    }
}

nonisolated private struct LegacyTask: Decodable {
    let id: UUID
    let title: String
    let createdAt: Date
    let completedAt: Date?
}
