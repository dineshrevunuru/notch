import NotchCore
import SwiftUI

/// The daily loop. Morning: settle what yesterday left, see how much time the calendar leaves, pick
/// up to three. During the day: the plan, with estimated vs. focused time. Evening: what got done,
/// where the rest goes, one line for tomorrow.
struct PlannerView: View {
    let model: NotchModel
    @Binding var selectedTask: UUID?
    @State private var replanning = false
    @State private var wrappingUp = false

    private var store: TaskStore { model.tasks }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let plan = model.todayPlan, !replanning {
                    if plan.isClosed {
                        ClosedDay(model: model, plan: plan, replan: { replanning = true })
                    } else if wrappingUp || isAfterHours {
                        WrapUp(model: model, plan: plan, cancel: { wrappingUp = false })
                    } else {
                        TodayPlan(model: model, plan: plan, selectedTask: $selectedTask,
                                  replan: { replanning = true }, wrapUp: { wrappingUp = true })
                    }
                } else {
                    PlanYourDay(model: model, existing: model.todayPlan, done: { replanning = false })
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isAfterHours: Bool {
        Calendar.current.component(.hour, from: model.now) >= model.workday.endHour
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)
                Text(model.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            WorkdayMenu(model: model)
        }
    }

    private var title: String {
        guard let plan = model.todayPlan, !replanning else { return "Plan your day" }
        if plan.isClosed { return "Day closed" }
        if wrappingUp || isAfterHours { return "Wrap up your day" }
        return "Today's plan"
    }
}

// MARK: - Morning

private struct PlanYourDay: View {
    let model: NotchModel
    let existing: DayPlan?
    let done: () -> Void
    @State private var picks: [UUID] = []
    @State private var started = false

    private var store: TaskStore { model.tasks }

    var body: some View {
        let now = model.now
        let calendar = Calendar.current
        let carry = Planner.carryOver(store.tasks, now: now, calendar: calendar)
        let candidates = Planner.candidates(store.tasks, now: now, calendar: calendar)
            .filter { !carry.contains($0) || picks.contains($0.id) }
        let chosen = picks.compactMap(store.task)
        let planned = Planner.plannedMinutes(chosen)
        let time = model.dayTime

        VStack(alignment: .leading, spacing: 32) {
            if let note = store.previousPlan(before: model.todayKey)?.note, !note.isEmpty {
                Label {
                    Text("Yesterday you wrote: ").foregroundStyle(.secondary) + Text(note)
                } icon: {
                    Image(systemName: "quote.opening").foregroundStyle(Palette.accent)
                }
                .font(.system(size: 15))
            }

            TimeBudget(free: time.free, meetings: time.meetings, planned: planned)

            if !carry.isEmpty {
                Step(number: 1, title: "Settle what's left over", detail: "Late, or still in Doing from an earlier day.") {
                    ForEach(carry) { task in
                        CarryOverRow(model: model, task: task)
                    }
                }
            }

            Step(number: carry.isEmpty ? 1 : 2, title: "Pick up to \(Planner.maxPicks)",
                 detail: "What has to be true by tonight? Estimates feed the time check above.") {
                if candidates.isEmpty {
                    Text("Nothing to pick from yet. Add tasks on the board first.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { task in
                    PickRow(
                        model: model,
                        task: task,
                        isPicked: picks.contains(task.id),
                        isFull: picks.count >= Planner.maxPicks,
                        toggle: { toggle(task.id) }
                    )
                }
            }

            HStack(spacing: 16) {
                Button {
                    store.savePlan(day: model.todayKey, picks: picks)
                    done()
                } label: {
                    Text(existing == nil ? "Start the day" : "Save the plan")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 22)
                        .frame(height: 40)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(picks.isEmpty)

                CapacityNote(capacity: Capacity.of(planned: planned, free: time.free), hasPicks: !picks.isEmpty)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            // Re-planning starts from the current picks; a fresh morning starts from what's already in Doing today.
            if let existing {
                picks = existing.taskIDs.filter { store.task($0)?.isDone == false }
            } else {
                let today = Calendar.current.startOfDay(for: model.now)
                picks = model.doingTasks.filter { ($0.startedAt ?? .distantPast) >= today }.prefix(Planner.maxPicks).map(\.id)
            }
        }
    }

    private func toggle(_ id: UUID) {
        if let i = picks.firstIndex(of: id) {
            picks.remove(at: i)
        } else if picks.count < Planner.maxPicks {
            picks.append(id)
        }
    }
}

private struct CarryOverRow: View {
    let model: NotchModel
    let task: NotchCore.TaskItem

    var body: some View {
        let store = model.tasks
        let now = model.now
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 15))
                Text(reason(now: now, calendar: calendar))
                    .font(.system(size: 12))
                    .foregroundStyle(TaskRules.isOverdue(task, now: now, calendar: calendar) ? Palette.late : .secondary)
            }
            Spacer()
            Button("Keep for today") { store.keepForToday(task.id, now: now) }
            Button("Tomorrow") { store.reschedule(task.id, to: tomorrow) }
            Button("Unschedule") { store.unschedule(task.id) }
                .help("No deadline, back in To Do")
        }
        .controlSize(.regular)
        .padding(.vertical, 6)
    }

    private func reason(now: Date, calendar: Calendar) -> String {
        if let due = task.due, TaskRules.isOverdue(task, now: now, calendar: calendar) {
            return TaskRules.lateness(due, now: now, calendar: calendar)
        }
        if let started = task.startedAt {
            return "In Doing since \(started.formatted(.dateTime.weekday(.abbreviated)))"
        }
        return ""
    }
}

private struct PickRow: View {
    let model: NotchModel
    let task: NotchCore.TaskItem
    let isPicked: Bool
    let isFull: Bool
    let toggle: () -> Void

    var body: some View {
        let now = model.now
        let calendar = Calendar.current
        HStack(spacing: 14) {
            Button(action: toggle) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isPicked ? Palette.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isPicked && isFull)
            .accessibilityLabel(isPicked ? "Remove \(task.title) from today" : "Pick \(task.title) for today")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 15, weight: isPicked ? .semibold : .regular))
                    .foregroundStyle(!isPicked && isFull ? Color.secondary : Color.primary)
                let detail = details(now: now, calendar: calendar)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(TaskRules.isOverdue(task, now: now, calendar: calendar) ? Palette.late : .secondary)
                }
            }
            Spacer()
            EstimateMenu(model: model, task: task)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .padding(.vertical, 4)
    }

    private func details(now: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        if let due = task.due {
            parts.append(TaskRules.isOverdue(task, now: now, calendar: calendar)
                ? TaskRules.lateness(due, now: now, calendar: calendar)
                : "Due \(TaskRules.dueLabel(due, now: now, calendar: calendar))")
        }
        if task.priority != .none { parts.append("\(task.priority.label) priority") }
        if let project = model.tasks.project(task.projectID) { parts.append(project.name) }
        if task.status == .doing { parts.append("In Doing") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - During the day

private struct TodayPlan: View {
    let model: NotchModel
    let plan: DayPlan
    @Binding var selectedTask: UUID?
    let replan: () -> Void
    let wrapUp: () -> Void

    var body: some View {
        let store = model.tasks
        let picks = model.todayPicks
        let open = picks.filter { !$0.isDone }
        let time = model.dayTime
        let focused = store.focusMinutes(on: model.now)

        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 28) {
                Stat(value: "\(picks.filter(\.isDone).count) of \(picks.count)", label: "done")
                Stat(value: DurationText.short(TimeInterval(focused * 60)), label: "focused today", show: focused > 0)
                Stat(value: DurationText.short(TimeInterval(time.free * 60)), label: "free in your workday", show: time.free > 0)
            }

            TimeBudget(free: time.free, meetings: time.meetings, planned: Planner.plannedMinutes(open))

            VStack(spacing: 12) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { index, task in
                    PlanCard(model: model, task: task, index: index + 1, isSelected: selectedTask == task.id)
                        .onTapGesture { selectedTask = task.id }
                }
            }

            HStack(spacing: 14) {
                Button("Change the plan", action: replan)
                Spacer()
                Button {
                    wrapUp()
                } label: {
                    Text("Wrap up the day")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

private struct PlanCard: View {
    let model: NotchModel
    let task: NotchCore.TaskItem
    let index: Int
    let isSelected: Bool

    var body: some View {
        let store = model.tasks
        let focused = store.focusMinutes(for: task.id)
        let isFocusTask = model.focusTask?.id == task.id && model.isFocusing

        HStack(alignment: .center, spacing: 16) {
            Text("\(index)")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22)

            Button { store.toggle(task.id) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(task.isDone ? Palette.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark \(task.title) as not done" : "Complete \(task.title)")

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 17, weight: .medium))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                HStack(spacing: 12) {
                    Text("Estimate \(DurationText.short(TimeInterval((task.estimateMinutes ?? Planner.defaultEstimate) * 60)))\(task.estimateMinutes == nil ? " (default)" : "")")
                    if focused > 0 {
                        Text("Focused \(DurationText.short(TimeInterval(focused * 60)))")
                            .foregroundStyle(focused > (task.estimateMinutes ?? Planner.defaultEstimate) ? Palette.late : .secondary)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !task.isDone {
                if isFocusTask {
                    Label("Focusing", systemImage: "timer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.851, green: 0.467, blue: 0.341))
                } else {
                    Button {
                        model.startFocus(task: task.id)
                    } label: {
                        Label("Focus", systemImage: "timer")
                    }
                    .help("Start a focus round on this")
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Palette.accent : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Evening

private struct WrapUp: View {
    let model: NotchModel
    let plan: DayPlan
    let cancel: () -> Void
    @State private var note = ""

    var body: some View {
        let store = model.tasks
        let calendar = Calendar.current
        let now = model.now
        let picks = model.todayPicks
        let unfinished = picks.filter { !$0.isDone }
        let doneToday = store.tasks
            .filter { ($0.completedAt.map { calendar.isDate($0, inSameDayAs: now) }) ?? false }
            .sorted { ($0.completedAt ?? now) < ($1.completedAt ?? now) }
        let focused = store.focusMinutes(on: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let distractions = store.distractionMinutes(on: now)
        let distracted = distractions.reduce(0) { $0 + $1.minutes }

        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 28) {
                    Stat(value: "\(picks.filter(\.isDone).count) of \(picks.count)", label: "planned done")
                    Stat(value: "\(doneToday.count)", label: "finished in all")
                    Stat(value: DurationText.short(TimeInterval(focused * 60)), label: "focused", show: focused > 0)
                    Stat(value: DurationText.short(TimeInterval(distracted * 60)), label: "on distractions", show: distracted > 0)
                }
                if !distractions.isEmpty {
                    Text(distractions.prefix(4).map { "\($0.name) \(DurationText.short(TimeInterval($0.minutes * 60)))" }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if !doneToday.isEmpty {
                Step(number: 1, title: "Done today", detail: nil) {
                    ForEach(doneToday) { task in
                        Label(task.title, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                            .labelStyle(DoneLabelStyle())
                    }
                }
            }

            if !unfinished.isEmpty {
                Step(number: doneToday.isEmpty ? 1 : 2, title: "Where does the rest go?", detail: "Decide now, so tomorrow's plan starts clean.") {
                    ForEach(unfinished) { task in
                        HStack(spacing: 14) {
                            Text(task.title).font(.system(size: 15))
                            Spacer()
                            Button("Tomorrow") { store.reschedule(task.id, to: tomorrow) }
                            Button("Back to To Do") { store.move(task.id, to: .todo) }
                            Button("Done") { store.complete(task.id) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Step(number: [!doneToday.isEmpty, !unfinished.isEmpty].filter { $0 }.count + 1,
                 title: "Tomorrow, start with…", detail: "One line. It's the first thing tomorrow's plan shows you.") {
                TextField("The first thing to do tomorrow", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .lineLimit(1...3)
            }

            HStack(spacing: 14) {
                Button {
                    store.closeDay(plan.day, note: note)
                } label: {
                    Text("Close the day")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 22)
                        .frame(height: 40)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Button("Not yet", action: cancel)
            }
        }
    }
}

private struct ClosedDay: View {
    let model: NotchModel
    let plan: DayPlan
    let replan: () -> Void

    var body: some View {
        let picks = model.todayPicks
        let focused = model.tasks.focusMinutes(on: model.now)

        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 28) {
                Stat(value: "\(picks.filter(\.isDone).count) of \(picks.count)", label: "planned done")
                Stat(value: DurationText.short(TimeInterval(focused * 60)), label: "focused", show: focused > 0)
                if let closed = plan.closedAt {
                    Stat(value: TimeText.clock(closed, calendar: .current), label: "closed at")
                }
            }
            if !plan.note.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tomorrow, start with").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text(plan.note).font(.system(size: 20, weight: .medium))
                }
            }
            Button("Plan again", action: replan)
        }
    }
}

// MARK: - Shared

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(.leading, 34)
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var show = true

    var body: some View {
        if show {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit())
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The day at a glance: meetings, planned work, and what's left free, with the 20% buffer marked.
private struct TimeBudget: View {
    let free: Int
    let meetings: Int
    let planned: Int

    var body: some View {
        let total = max(1, free + meetings)
        let capacity = Capacity.of(planned: planned, free: free)

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    HStack(spacing: 2) {
                        if meetings > 0 {
                            Rectangle().fill(Color.primary.opacity(0.28))
                                .frame(width: w * CGFloat(meetings) / CGFloat(total))
                        }
                        if planned > 0 {
                            Rectangle().fill(capacity == .over ? Palette.late : Palette.accent)
                                .frame(width: min(w, w * CGFloat(planned) / CGFloat(total)))
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                    // The buffer line: past this, the plan leaves no breathing room.
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: 18)
                        .offset(x: w * CGFloat(meetings + Int(Double(free) * (1 - Capacity.buffer))) / CGFloat(total) - 1)
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            HStack(spacing: 18) {
                legend(color: Color.primary.opacity(0.28), "Meetings \(minutes(meetings))", show: meetings > 0)
                legend(color: capacity == .over ? Palette.late : Palette.accent, "Planned \(minutes(planned))")
                legend(color: Color.primary.opacity(0.07), "Free \(minutes(free))")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func minutes(_ m: Int) -> String { m <= 0 ? "0m" : DurationText.short(TimeInterval(m * 60)) }

    @ViewBuilder
    private func legend(color: Color, _ text: String, show: Bool = true) -> some View {
        if show {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 8)
                Text(text)
            }
        }
    }
}

private struct CapacityNote: View {
    let capacity: Capacity
    let hasPicks: Bool

    var body: some View {
        if hasPicks {
            switch capacity {
            case .fits:
                Label("Fits, with room to spare", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            case .tight:
                Label("No buffer left. Consider cutting one.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Palette.late)
            case .over:
                Label("More than your day holds. Cut one.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.late)
            }
        }
    }
}

struct EstimateMenu: View {
    let model: NotchModel
    let task: NotchCore.TaskItem
    static let options = [15, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { minutes in
                Button(DurationText.short(TimeInterval(minutes * 60))) { model.tasks.setEstimate(task.id, minutes: minutes) }
            }
            if task.estimateMinutes != nil {
                Divider()
                Button("No Estimate") { model.tasks.setEstimate(task.id, minutes: nil) }
            }
        } label: {
            Text(task.estimateMinutes.map { DurationText.short(TimeInterval($0 * 60)) } ?? "Estimate")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How long you expect this to take")
    }
}

private struct WorkdayMenu: View {
    let model: NotchModel

    var body: some View {
        Menu {
            Section("Starts") {
                ForEach(5...12, id: \.self) { h in
                    Button(Workday(startHour: h, endHour: 24).label.components(separatedBy: " – ").first ?? "") {
                        model.workday = Workday(startHour: h, endHour: max(model.workday.endHour, h + 1))
                    }
                }
            }
            Section("Ends") {
                ForEach(14...23, id: \.self) { h in
                    Button(Workday(startHour: 0, endHour: h).label.components(separatedBy: " – ").last ?? "") {
                        model.workday = Workday(startHour: min(model.workday.startHour, h - 1), endHour: h)
                    }
                }
            }
        } label: {
            Label("Workday \(model.workday.label)", systemImage: "clock")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Your working hours: used to work out free time, and when the notch asks you to plan and wrap up")
    }
}

private struct DoneLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(Palette.accent)
            configuration.title
        }
    }
}
