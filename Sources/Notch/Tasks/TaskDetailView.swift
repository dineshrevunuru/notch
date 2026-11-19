import NotchCore
import SwiftUI

/// Everything about one task. Every control writes straight to the store, reading the task
/// fresh each time, so a change made elsewhere (the notch, a checkbox in the list) is never undone.
struct TaskDetailView: View {
    let model: NotchModel
    let taskID: UUID
    let select: (UUID?) -> Void

    @State private var tagText = ""
    @State private var newSubtask = ""
    @State private var confirmDelete = false
    @FocusState private var tagsFocused: Bool

    private var store: TaskStore { model.tasks }

    var body: some View {
        if let task = store.task(taskID) {
            form(task)
                .onAppear { tagText = task.tags.joined(separator: ", ") }
        } else {
            Text("This task was deleted.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func form(_ task: NotchCore.TaskItem) -> some View {
        Form {
            Section {
                TextField("Title", text: field(\.title, task), prompt: Text("Title"), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 20, weight: .semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                TextField("Notes", text: field(\.notes, task), prompt: Text("Notes"), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .lineLimit(3...12)
                if let parent = task.parentID.flatMap(store.task) {
                    Button { select(parent.id) } label: {
                        Label("Subtask of \(parent.title)", systemImage: "arrow.turn.left.up")
                    }
                    .buttonStyle(.link)
                }
            }

            Section("When") {
                Toggle("Deadline", isOn: Binding(
                    get: { store.task(taskID)?.due != nil },
                    set: { on in edit { $0.due = on ? .day(model.now) : nil } }
                ))
                if let due = task.due {
                    DatePicker(
                        "Due",
                        selection: Binding(
                            get: { store.task(taskID)?.due?.date ?? due.date },
                            set: { date in edit { t in
                                let timed = t.due?.hasTime ?? false
                                t.due = timed ? DueDate(date: date, hasTime: true) : .day(date)
                            } }
                        ),
                        displayedComponents: due.hasTime ? [.date, .hourAndMinute] : [.date]
                    )
                    Toggle("At a set time", isOn: Binding(
                        get: { store.task(taskID)?.due?.hasTime ?? false },
                        set: { timed in edit { t in
                            guard let current = t.due else { return }
                            t.due = timed
                                ? DueDate(date: Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: current.date) ?? current.date, hasTime: true)
                                : .day(current.date)
                        } }
                    ))
                }

                LabeledContent("Estimate") {
                    HStack(spacing: 10) {
                        let focused = store.focusMinutes(for: taskID)
                        if focused > 0 {
                            Text("Focused \(DurationText.short(TimeInterval(focused * 60)))")
                                .foregroundStyle(.secondary)
                        }
                        EstimateMenu(model: model, task: task)
                    }
                }

                Toggle("Remind me", isOn: Binding(
                    get: { store.task(taskID)?.reminder != nil },
                    set: { on in edit { t in t.reminder = on ? defaultReminder(for: t) : nil } }
                ))
                if task.reminder != nil {
                    DatePicker("At", selection: Binding(
                        get: { store.task(taskID)?.reminder ?? model.now },
                        set: { date in edit { $0.reminder = date } }
                    ))
                    if TaskRules.isRinging(task, now: model.now) {
                        HStack {
                            Label("Ringing now", systemImage: "bell.fill").foregroundStyle(Palette.accent)
                            Spacer()
                            Button("Snooze 10 min") { store.snoozeReminder(taskID) }
                            Button("Dismiss") { store.dismissReminder(taskID) }
                        }
                    } else if let snoozed = task.snoozedUntil, snoozed > model.now {
                        Text("Snoozed until \(TimeText.clock(snoozed, calendar: .current))")
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Repeat", selection: Binding(
                    get: { store.task(taskID)?.recurrence?.unit },
                    set: { unit in edit { t in
                        t.recurrence = unit.map { Recurrence(unit: $0, interval: t.recurrence?.interval ?? 1) }
                    } }
                )) {
                    Text("Never").tag(Recurrence.Unit?.none)
                    Divider()
                    Text("Daily").tag(Recurrence.Unit?.some(.day))
                    Text("Weekly").tag(Recurrence.Unit?.some(.week))
                    Text("Monthly").tag(Recurrence.Unit?.some(.month))
                    Text("Yearly").tag(Recurrence.Unit?.some(.year))
                }
                if let rule = task.recurrence {
                    Stepper(value: Binding(
                        get: { store.task(taskID)?.recurrence?.interval ?? 1 },
                        set: { n in edit { $0.recurrence?.interval = max(1, n) } }
                    ), in: 1...30) {
                        Text(rule.label)
                    }
                    if task.due == nil {
                        Text("Repeats from the day you finish it.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Organize") {
                Picker("Status", selection: Binding(
                    get: { store.task(taskID)?.column ?? .todo },
                    set: { column in store.move(taskID, to: column) }
                )) {
                    ForEach(BoardColumn.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Project", selection: Binding(
                    get: { store.task(taskID)?.projectID },
                    set: { id in edit { $0.projectID = id } }
                )) {
                    Text("Inbox").tag(UUID?.none)
                    if !store.projects.isEmpty { Divider() }
                    ForEach(store.sortedProjects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .disabled(task.parentID != nil)
                .help(task.parentID != nil ? "Subtasks live in their parent's project" : "")

                Picker("Priority", selection: Binding(
                    get: { store.task(taskID)?.priority ?? .none },
                    set: { p in edit { $0.priority = p } }
                )) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Tags", text: $tagText, prompt: Text("Tags, separated by commas"))
                    .focused($tagsFocused)
                    .onSubmit(commitTags)
                    .onChange(of: tagsFocused) { _, focused in if !focused { commitTags() } }
            }

            Section("Subtasks") {
                ForEach(store.children(of: taskID)) { child in
                    HStack(spacing: 10) {
                        Button { store.toggle(child.id) } label: {
                            Image(systemName: child.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(child.isDone ? Palette.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(child.isDone ? "Mark \(child.title) as not done" : "Complete \(child.title)")
                        Text(child.title)
                            .strikethrough(child.isDone)
                            .foregroundStyle(child.isDone ? .secondary : .primary)
                        Spacer()
                        Button { select(child.id) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Open \(child.title)")
                    }
                }
                TextField("Add a subtask", text: $newSubtask, prompt: Text("Add a subtask"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        store.add(newSubtask, parent: taskID)
                        newSubtask = ""
                    }
            }

            Section {
                let blockers = task.blockedBy.compactMap(store.task)
                ForEach(blockers) { blocker in
                    HStack(spacing: 10) {
                        Image(systemName: blocker.isDone ? "checkmark.circle.fill" : "lock")
                            .foregroundStyle(blocker.isDone ? Palette.accent : .secondary)
                        Button(blocker.title) { select(blocker.id) }
                            .buttonStyle(.plain)
                            .strikethrough(blocker.isDone)
                        Spacer()
                        Button { store.removeDependency(taskID, blockedBy: blocker.id) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stop waiting on \(blocker.title)")
                    }
                }
                let candidates = store.dependencyCandidates(for: taskID)
                Menu("Add a task this waits on") {
                    ForEach(candidates.prefix(40)) { candidate in
                        Button(candidate.title) { store.addDependency(taskID, blockedBy: candidate.id) }
                    }
                }
                .disabled(candidates.isEmpty)

                let dependents = store.dependents(of: taskID)
                if !dependents.isEmpty {
                    Text("Holding up: " + dependents.map(\.title).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Waiting on")
            } footer: {
                Text("A task stays locked until everything it waits on is done. Loops aren't offered.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Added \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete Task", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                store.delete(taskID)
                select(nil)
            }
        } message: {
            let kids = store.children(of: taskID).count
            Text(kids > 0 ? "Its \(kids) subtask\(kids == 1 ? "" : "s") will be deleted too. This can't be undone." : "This can't be undone.")
        }
    }

    // MARK: Editing

    /// Applies a change to the latest copy of the task.
    private func edit(_ change: (inout NotchCore.TaskItem) -> Void) {
        guard var task = store.task(taskID) else { return }
        change(&task)
        store.update(task)
    }

    private func field<V>(_ keyPath: WritableKeyPath<NotchCore.TaskItem, V>, _ fallback: NotchCore.TaskItem) -> Binding<V> {
        Binding(
            get: { store.task(taskID)?[keyPath: keyPath] ?? fallback[keyPath: keyPath] },
            set: { value in edit { $0[keyPath: keyPath] = value } }
        )
    }

    private func commitTags() {
        let tags = Tags.parse(tagText)
        edit { $0.tags = tags }
        tagText = tags.joined(separator: ", ")
    }

    /// At the deadline if it has a time; otherwise 9 AM on the deadline day, or an hour from now.
    private func defaultReminder(for task: NotchCore.TaskItem) -> Date {
        if let due = task.due {
            if due.hasTime { return due.date }
            let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due.date) ?? due.date
            if nine > model.now { return nine }
        }
        let inAnHour = model.now.addingTimeInterval(3600)
        return Calendar.current.date(bySetting: .second, value: 0, of: inAnHour) ?? inAnHour
    }
}
