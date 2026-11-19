import AppKit
import NotchCore
import SwiftUI

/// Colors for the task window. Unlike the notch, this is an ordinary window, so it follows
/// light and dark mode; soft white, warm ink, one accent, red only for late.
enum Palette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.55, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.24, blue: 0.93, alpha: 1)
    })
    static let late = Color(nsColor: .systemRed)
}

enum TaskList: Hashable {
    case planner, board, today, upcoming, inbox, completed
    case project(UUID)
    case tag(String)
}

struct TaskAppView: View {
    let model: NotchModel
    @State private var list: TaskList? = .board
    @State private var selectedTask: UUID?

    /// Opens on the Planner while today still needs a plan, otherwise on the Board.
    init(model: NotchModel, list: TaskList? = nil, selectedTask: UUID? = nil) {
        self.model = model
        _list = State(initialValue: list ?? model.requestedList ?? (model.needsPlan ? .planner : .board))
        _selectedTask = State(initialValue: selectedTask)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, selection: $list)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            switch list ?? .board {
            case .planner:
                PlannerView(model: model, selectedTask: $selectedTask)
            case .board:
                BoardView(model: model, selectedTask: $selectedTask)
            default:
                TaskListView(model: model, list: list ?? .today, selectedTask: $selectedTask)
            }
        }
        .inspector(isPresented: Binding(
            get: { selectedTask != nil },
            set: { if !$0 { selectedTask = nil } }
        )) {
            Group {
                if let id = selectedTask {
                    TaskDetailView(model: model, taskID: id, select: { selectedTask = $0 })
                        .id(id)
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
        }
        .tint(Palette.accent)
        .onChange(of: list) { _, _ in selectedTask = nil }
        .onAppear { model.requestedList = nil }
        .onChange(of: model.requestedList) { _, requested in
            guard let requested else { return }
            list = requested
            model.requestedList = nil
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let model: NotchModel
    @Binding var selection: TaskList?
    @State private var newProject = ""
    @State private var creatingProject = false
    @State private var renaming: Project?
    @State private var renameText = ""
    @State private var deleting: Project?

    var body: some View {
        let store = model.tasks
        let calendar = Calendar.current
        let todayCount = TaskRules.today(store.tasks, now: model.now, calendar: calendar).count
        let inboxCount = store.tasks.filter { !$0.isDone && $0.projectID == nil && $0.parentID == nil }.count

        List(selection: $selection) {
            Section {
                let doing = store.tasks.filter { !$0.isDone && $0.status == .doing && $0.parentID == nil }.count
                SidebarRow(title: "Planner", symbol: model.needsPlan ? "sun.max.fill" : "sun.max", count: nil).tag(TaskList.planner)
                SidebarRow(title: "Board", symbol: "rectangle.split.3x1", count: doing).tag(TaskList.board)
                SidebarRow(title: "Today", symbol: "star", count: todayCount).tag(TaskList.today)
                SidebarRow(title: "Upcoming", symbol: "calendar", count: nil).tag(TaskList.upcoming)
                SidebarRow(title: "Inbox", symbol: "tray", count: inboxCount).tag(TaskList.inbox)
                SidebarRow(title: "Completed", symbol: "checkmark.circle", count: nil).tag(TaskList.completed)
            }

            Section("Projects") {
                ForEach(store.sortedProjects) { project in
                    let open = store.tasks.filter { !$0.isDone && $0.projectID == project.id && $0.parentID == nil }.count
                    SidebarRow(title: project.name, symbol: "folder", count: open)
                        .tag(TaskList.project(project.id))
                        .contextMenu {
                            Button("Rename…") { renameText = project.name; renaming = project }
                            Button("Delete…", role: .destructive) { deleting = project }
                        }
                }
                Button { newProject = ""; creatingProject = true } label: {
                    Label("New Project…", systemImage: "plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            let tags = store.allTags
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        SidebarRow(title: tag, symbol: "number", count: nil).tag(TaskList.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("New project", isPresented: $creatingProject) {
            TextField("Name", text: $newProject)
            Button("Create") {
                if let project = store.addProject(newProject) { selection = .project(project.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = renaming { store.renameProject(p.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete Project", role: .destructive) {
                if let p = deleting {
                    store.deleteProject(p.id)
                    if selection == .project(p.id) { selection = .inbox }
                }
            }
        } message: {
            Text("Its tasks move to the Inbox. Nothing else is deleted.")
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int?

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count, count > 0 {
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
    }
}

// MARK: - List

private struct TaskListView: View {
    let model: NotchModel
    let list: TaskList
    @Binding var selectedTask: UUID?
    @State private var draft = ""

    private var store: TaskStore { model.tasks }
    private var calendar: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)
                if let subtitle {
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 18)

            if list != .completed {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.accent)
                    TextField(addPlaceholder, text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit(add)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }

            let sections = self.sections
            if sections.allSatisfy({ $0.rows.isEmpty }) {
                Spacer()
                Text(emptyText)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(selection: $selectedTask) {
                    ForEach(sections, id: \.title) { section in
                        if section.rows.isEmpty {
                            EmptyView()
                        } else if section.title.isEmpty {
                            rows(section.rows)
                        } else {
                            Section {
                                rows(section.rows)
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(section.isLate ? Palette.late : .secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 420)
    }

    @ViewBuilder
    private func rows(_ rows: [ListRow]) -> some View {
        ForEach(rows) { row in
            TaskRowView(model: model, task: row.task, depth: row.depth, showsProject: showsProject)
                .tag(row.task.id)
        }
    }

    // MARK: Content per list

    private struct ListRow: Identifiable {
        let task: NotchCore.TaskItem
        let depth: Int
        var id: UUID { task.id }
    }

    private struct ListSection {
        let title: String
        var isLate = false
        let rows: [ListRow]
    }

    private var sections: [ListSection] {
        let now = model.now
        switch list {
        case .board, .planner:
            return []
        case .today:
            let today = TaskRules.today(store.tasks, now: now, calendar: calendar)
            let late = today.filter { TaskRules.isOverdue($0, now: now, calendar: calendar) }
            let rest = today.filter { !TaskRules.isOverdue($0, now: now, calendar: calendar) }
            return [
                ListSection(title: "Overdue", isLate: true, rows: late.map { ListRow(task: $0, depth: 0) }),
                ListSection(title: late.isEmpty ? "" : "Today", rows: rest.map { ListRow(task: $0, depth: 0) }),
            ]
        case .upcoming:
            return TaskRules.upcoming(store.tasks, now: now, calendar: calendar).map { group in
                ListSection(title: dayHeader(group.day), rows: group.tasks.map { ListRow(task: $0, depth: 0) })
            }
        case .inbox:
            return [ListSection(title: "", rows: tree(store.tasks.filter { $0.projectID == nil }))]
        case .project(let id):
            return [ListSection(title: "", rows: tree(store.tasks.filter { $0.projectID == id }))]
        case .tag(let tag):
            let tagged = store.tasks
                .filter { !$0.isDone && $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                .sorted { ($0.due?.date ?? .distantFuture) < ($1.due?.date ?? .distantFuture) }
            return [ListSection(title: "", rows: tagged.map { ListRow(task: $0, depth: 0) })]
        case .completed:
            let done = store.tasks.filter(\.isDone).sorted { ($0.completedAt ?? now) > ($1.completedAt ?? now) }
            let grouped = Dictionary(grouping: done.prefix(300)) { calendar.startOfDay(for: $0.completedAt ?? now) }
            return grouped.keys.sorted(by: >).map { day in
                ListSection(title: dayHeader(day), rows: grouped[day]!.map { ListRow(task: $0, depth: 0) })
            }
        }
    }

    /// Open top-level tasks with their subtasks (open and done) indented beneath them.
    private func tree(_ pool: [NotchCore.TaskItem]) -> [ListRow] {
        var rows: [ListRow] = []
        func walk(_ parent: UUID?, depth: Int) {
            let level = pool
                .filter { $0.parentID == parent && (depth > 0 || !$0.isDone) }
                .sorted { $0.sortOrder < $1.sortOrder }
            for task in level {
                rows.append(ListRow(task: task, depth: depth))
                walk(task.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return rows
    }

    private func dayHeader(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var showsProject: Bool {
        switch list {
        case .today, .upcoming, .tag, .completed, .board, .planner: true
        case .inbox, .project: false
        }
    }

    private var title: String {
        switch list {
        case .board: "Board"
        case .planner: "Planner"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .inbox: "Inbox"
        case .completed: "Completed"
        case .project(let id): store.project(id)?.name ?? "Project"
        case .tag(let tag): "#\(tag)"
        }
    }

    private var subtitle: String? {
        switch list {
        case .today: model.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .inbox: "Tasks without a project"
        default: nil
        }
    }

    private var addPlaceholder: String {
        switch list {
        case .board, .planner: "Add a card"
        case .today: "Add a task for today"
        case .upcoming: "Add a task for tomorrow"
        case .inbox: "Add to the Inbox"
        case .project: "Add to \(title)"
        case .tag(let tag): "Add a task tagged #\(tag)"
        case .completed: ""
        }
    }

    private var emptyText: String {
        switch list {
        case .board, .planner: "No cards yet."
        case .today: "Nothing due today."
        case .upcoming: "Nothing scheduled ahead."
        case .completed: "Finished tasks show up here."
        default: "No tasks here yet."
        }
    }

    private func add() {
        let title = draft
        draft = ""
        switch list {
        case .board, .planner:
            store.add(title)
        case .today:
            store.add(title, due: .day(model.now))
        case .upcoming:
            store.add(title, due: .day(calendar.date(byAdding: .day, value: 1, to: model.now) ?? model.now))
        case .inbox:
            store.add(title)
        case .project(let id):
            store.add(title, project: id)
        case .tag(let tag):
            if var task = store.add(title) {
                task.tags = [tag]
                store.update(task)
            }
        case .completed:
            break
        }
    }
}

// MARK: - Row

private struct TaskRowView: View {
    let model: NotchModel
    let task: NotchCore.TaskItem
    let depth: Int
    let showsProject: Bool

    var body: some View {
        let store = model.tasks
        let now = model.now
        let calendar = Calendar.current
        let blockers = store.openBlockers(of: task.id)

        HStack(alignment: .top, spacing: 12) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(task.isDone ? Palette.accent : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark \(task.title) as not done" : "Complete \(task.title)")

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 15))
                    .foregroundStyle(task.isDone || !blockers.isEmpty ? Color.secondary : Color.primary)
                    .strikethrough(task.isDone)
                    .lineLimit(2)

                let meta = metaItems(blockers: blockers, now: now, calendar: calendar)
                if !meta.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(meta, id: \.text) { item in
                            Label(item.text, systemImage: item.symbol)
                                .foregroundStyle(item.isLate ? Palette.late : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 12))
                    .labelStyle(.titleAndIcon)
                }
            }

            Spacer(minLength: 8)

            if task.priority != .none {
                Text(task.priority.marks)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("\(task.priority.label) priority")
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, CGFloat(depth) * 28)
        .contextMenu {
            Button(task.isDone ? "Mark as Not Done" : "Complete") { store.toggle(task.id) }
            if !task.isDone {
                Button("Focus on This") { model.startFocus(task: task.id) }
            }
            Divider()
            Menu("Priority") {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button(p.label) { var t = task; t.priority = p; store.update(t) }
                }
            }
            Menu("Move to") {
                Button("Inbox") { var t = task; t.projectID = nil; store.update(t) }
                ForEach(store.sortedProjects) { project in
                    Button(project.name) { var t = task; t.projectID = project.id; store.update(t) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(task.id) }
        }
    }

    private struct MetaItem {
        let text: String
        let symbol: String
        var isLate = false
    }

    private func metaItems(blockers: [NotchCore.TaskItem], now: Date, calendar: Calendar) -> [MetaItem] {
        var items: [MetaItem] = []
        if task.status == .doing, !task.isDone {
            items.append(MetaItem(text: "Doing", symbol: "play.fill"))
        }
        if let due = task.due, !task.isDone {
            let late = TaskRules.isOverdue(task, now: now, calendar: calendar)
            items.append(MetaItem(
                text: late ? TaskRules.lateness(due, now: now, calendar: calendar) : TaskRules.dueLabel(due, now: now, calendar: calendar),
                symbol: "calendar", isLate: late
            ))
        }
        if let at = task.alertTime, !task.isDone, !task.reminderHandled {
            items.append(MetaItem(text: TaskRules.isRinging(task, now: now) ? "Ringing" : TimeText.weekdayClock(at, calendar: calendar), symbol: "bell"))
        }
        if let rule = task.recurrence { items.append(MetaItem(text: rule.label, symbol: "repeat")) }
        if let progress = model.tasks.subtaskProgress(of: task.id) {
            items.append(MetaItem(text: "\(progress.done)/\(progress.total)", symbol: "checklist"))
        }
        if let first = blockers.first, !task.isDone {
            let more = blockers.count > 1 ? " +\(blockers.count - 1)" : ""
            items.append(MetaItem(text: "Waiting on \(first.title)\(more)", symbol: "lock"))
        }
        if showsProject, let project = model.tasks.project(task.projectID) {
            items.append(MetaItem(text: project.name, symbol: "folder"))
        }
        for tag in task.tags.prefix(3) { items.append(MetaItem(text: tag, symbol: "number")) }
        if task.isDone, let done = task.completedAt {
            items.append(MetaItem(text: TimeText.weekdayClock(done, calendar: calendar), symbol: "checkmark"))
        }
        return items
    }
}
