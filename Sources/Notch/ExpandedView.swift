import NotchCore
import ServiceManagement
import SwiftUI

/// The open notch: what you're doing now, then everything ahead in one list.
struct ExpandedView: View {
    let model: NotchModel
    let metrics: NotchMetrics

    private static let sidePadding: CGFloat = 34

    var body: some View {
        Group {
            if model.isFocusing {
                FocusModeView(model: model, metrics: metrics)
            } else {
                regular
            }
        }
        .padding(.horizontal, Self.sidePadding + NotchMetrics.openTopRadius)
        .padding(.bottom, 22)
        .frame(width: NotchMetrics.openWidth + NotchMetrics.openTopRadius * 2,
               height: model.openHeight,
               alignment: .topLeading)
        .contextMenu { AppMenu(model: model) }
    }

    private var regular: some View {
        // What leads the panel, in order: a running break timer; the meeting you're in; the card
        // you're doing; otherwise where your day stands.
        let session = model.pomodoro.isActive
        let nowTask = model.nowTask

        return VStack(alignment: .leading, spacing: 0) {
            // The band beside the camera holds the glance wings, drawn on top by NotchRootView.
            Color.clear.frame(height: metrics.notchSize.height)

            Group {
                if session {
                    PomodoroBlock(model: model)
                } else if let nowTask {
                    NowTaskHero(model: model, task: nowTask)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        StatusBlock(model: model)
                        Spacer(minLength: 0)
                        StartFocusPill(model: model)
                    }
                }
            }
            .padding(.top, session ? 12 : 16)

            AgendaSection(model: model)
                .padding(.top, session ? 16 : 22)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Now

/// The card you're doing, as the one dominant thing: its full name, where your day stands,
/// and the two things you do to it — finish it, or focus on it.
private struct NowTaskHero: View {
    let model: NotchModel
    let task: NotchCore.TaskItem

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
                detail
                    .font(.system(size: 15))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Done") { model.tasks.complete(task.id) }
                .buttonStyle(PillButtonStyle())
                .help("Mark \(task.title) done")
            Button { model.startFocus(task: task.id) } label: {
                Text("Focus \(model.pomodoro.plan.focusMinutes)m")
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .help("Start a focus round on this")
        }
    }

    private var detail: Text {
        let doing = Text("Doing now").foregroundStyle(Ink.accent)
        guard model.calendar.access == .granted else { return doing }
        let status = model.status
        // "Free for 1h 43m" → "free for 1h 43m", to read on after "Doing now ·".
        let phrase = status.kind == .busy ? status.headline : status.headline.prefix(1).lowercased() + status.headline.dropFirst()
        return doing + Text(" · \(phrase)").foregroundStyle(Ink.secondary)
    }
}

// MARK: - Focus mode

/// A focus round, open: the countdown, what you're working on, and nothing else competing.
/// Task lists and counts are gone until the break; only the next meeting stays, so focus never
/// runs into it blind.
private struct FocusModeView: View {
    let model: NotchModel
    let metrics: NotchMetrics

    var body: some View {
        let timer = model.pomodoro
        let paused = timer.isPaused
        let remaining = timer.remaining(at: model.now) ?? 0
        let round = timer.round ?? 1
        let rounds = timer.plan.rounds

        VStack(alignment: .leading, spacing: 0) {
            // The band holds the glance wings: the task on the left, the timer on the right.
            Color.clear.frame(height: metrics.notchSize.height)

            HStack(alignment: .center, spacing: 24) {
                Text(DurationText.countdown(remaining))
                    .font(.system(size: 64, weight: .semibold).monospacedDigit())
                    .tracking(-1.5)
                    .foregroundStyle(paused ? Ink.secondary : Ink.focus)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("\(DurationText.short(remaining)) left in this focus round\(paused ? ", paused" : "")")
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    CircleButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause") {
                        model.togglePause()
                    }
                    CircleButton(symbol: "forward.end.fill", label: "End round now") { model.skipPhase() }
                    CircleButton(symbol: "stop.fill", label: "Stop session") { model.stopFocus() }
                }
            }
            .padding(.top, 14)

            ProgressBar(progress: timer.progress(at: model.now) ?? 0, tint: paused ? Ink.secondary : Ink.focus)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Text(paused ? "Focus mode · paused" : "Focus mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(paused ? Ink.secondary : Ink.focus)
                RoundDots(round: round, rounds: rounds, tint: Ink.focus, size: 6)
                Text("Round \(round) of \(rounds)")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.top, 12)

            WorkingOn(model: model)
                .padding(.top, 18)

            Spacer(minLength: 0)

            if let note = model.focusCalendarNote {
                Label(note, systemImage: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// The task this session is about: finish it from here, or pick one.
private struct WorkingOn: View {
    let model: NotchModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Working on")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                if let task = model.focusTask {
                    Text(task.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    TaskPicker(model: model, prompt: "Choose a task")
                }
            }
            Spacer(minLength: 0)
            if let task = model.focusTask {
                TaskPicker(model: model, prompt: "Switch")
                Button("Done") { model.tasks.complete(task.id) }
                    .buttonStyle(PillButtonStyle())
                    .help("Mark \(task.title) done")
            }
        }
    }
}

private struct TaskPicker: View {
    let model: NotchModel
    let prompt: String

    var body: some View {
        let today = model.todayTasks.filter { !$0.isDone }
        let others = model.tasks.tasks
            .filter { task in !task.isDone && !today.contains { $0.id == task.id } }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(12)
        Menu {
            if !today.isEmpty {
                Section("Today") {
                    ForEach(today) { task in Button(task.title) { model.setFocusTask(task.id) } }
                }
            }
            if !others.isEmpty {
                Section("Other tasks") {
                    ForEach(Array(others)) { task in Button(task.title) { model.setFocusTask(task.id) } }
                }
            }
            if model.focusTask != nil {
                Divider()
                Button("No Task") { model.setFocusTask(nil) }
            }
        } label: {
            Text(prompt)
                .font(.system(size: prompt == "Switch" ? 14 : 20, weight: .semibold))
                .foregroundStyle(prompt == "Switch" ? Ink.secondary : Ink.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(prompt == "Switch" ? .hidden : .visible)
        .fixedSize()
    }
}

// MARK: - Status

private struct StatusBlock: View {
    let model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch model.calendar.access {
            case .granted:
                let status = model.status
                Text(status.headline)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Ink.primary)
                if let detail = status.detail {
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.secondary)
                }
            case .unknown:
                Text("Waiting for calendar access")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Ink.primary)
                Text("Allow it in the prompt to see your day here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.secondary)
            case .denied:
                Text("Calendar access is off")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Ink.primary)
                Button("Turn it on in System Settings") { model.calendar.openPrivacySettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.accent)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Pomodoro

/// Idle, or waiting between rounds: one pill starts the next focus round. Right-click to change the plan.
private struct StartFocusPill: View {
    let model: NotchModel

    var body: some View {
        let timer = model.pomodoro
        let plan = timer.plan
        let label: String = if case .ready(let round) = timer.state, round > 1 {
            "Start round \(round) of \(plan.rounds)"
        } else {
            "Focus \(plan.focusMinutes)m"
        }

        Button { model.startFocus() } label: {
            Text(label)
        }
        .buttonStyle(PillButtonStyle())
        .help("\(plan.name) Pomodoro: \(plan.summary). Right-click to change.")
        .contextMenu {
            ForEach(PomodoroTimer.Plan.all) { option in
                Button {
                    model.setPlan(option)
                } label: {
                    if option == plan {
                        Label("\(option.name) · \(option.summary)", systemImage: "checkmark")
                    } else {
                        Text("\(option.name) · \(option.summary)")
                    }
                }
            }
            if case .ready = timer.state {
                Divider()
                Button("Start Over from Round 1") { model.stopFocus() }
            }
        }
    }
}

/// The running session: a large countdown, what it is, how far along, and three controls.
private struct PomodoroBlock: View {
    let model: NotchModel

    var body: some View {
        let timer = model.pomodoro
        let phase = timer.phase ?? .focus
        let round = timer.round ?? 1
        let rounds = timer.plan.rounds
        let remaining = timer.remaining(at: model.now) ?? 0
        let paused = timer.isPaused

        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(DurationText.countdown(remaining))
                        .font(.system(size: 38, weight: .semibold).monospacedDigit())
                        .tracking(-0.5)
                        .foregroundStyle(paused ? Ink.secondary : Ink.accent)
                        .contentTransition(.numericText(countsDown: true))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(paused ? "Paused · \(phase.label)" : phase.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.primary)
                        HStack(spacing: 8) {
                            RoundDots(round: round, rounds: rounds, tint: Ink.accent, size: 6)
                            Text("Round \(round) of \(rounds)")
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                }
                ProgressBar(progress: timer.progress(at: model.now) ?? 0, tint: paused ? Ink.secondary : Ink.accent)
                    .frame(maxWidth: 380)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(phase.label)\(paused ? ", paused" : ""), \(DurationText.short(remaining)) left, round \(round) of \(rounds)")

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                CircleButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause") {
                    model.togglePause()
                }
                CircleButton(symbol: "forward.end.fill", label: phase.isBreak ? "Skip break" : "End round now") {
                    model.skipPhase()
                }
                CircleButton(symbol: "stop.fill", label: "Stop session") {
                    model.stopFocus()
                }
            }
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.hairline)
                Capsule().fill(tint).frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct CircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Ink.primary.opacity(hovering ? 0.16 : 0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill = prominent
            ? Ink.primary.opacity(configuration.isPressed ? 0.8 : hovering ? 0.92 : 1)
            : Ink.primary.opacity(configuration.isPressed ? 0.20 : hovering ? 0.15 : 0.10)
        configuration.label
            .font(.system(size: 14, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.black : Ink.primary)
            .fixedSize()
            .frame(height: 32)
            .padding(.horizontal, 14)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

// MARK: - Agenda

/// Everything ahead, in one list across the full width: meetings and tasks together, in time
/// order, so names fit and nothing is said twice. At most four rows; the rest is one tap away.
private struct AgendaSection: View {
    let model: NotchModel
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let agenda = model.agenda
        let items = agenda.items
        let shown = agenda.shown
        let hidden = agenda.hidden
        let done = agenda.done

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                ColumnLabel("Up next", count: items.count)
                Spacer()
                headerLink
            }

            if let error = model.tasks.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                    .padding(.bottom, 6)
            }

            if items.isEmpty && done.isEmpty {
                Text(model.calendar.access == .granted ? "Nothing else today" : "Nothing else on your list")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.secondary)
                    .frame(height: Row.height)
            }
            ForEach(shown) { item in
                switch item {
                case .task(let task): NotchTaskRow(task: task, model: model)
                case .event(let event): EventRow(event: event, model: model)
                }
            }
            if hidden > 0 {
                Button { model.openTasksWindow?() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24)
                        Text("\(hidden) more in All tasks")
                            .font(.system(size: 15))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Ink.tertiary)
                    .frame(height: Row.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(done) { task in
                NotchTaskRow(task: task, model: model)
            }

            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 24)
                TextField("Add for today", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.primary)
                    .focused($fieldFocused)
                    .onSubmit {
                        model.addTodayTask(draft)
                        draft = ""
                        fieldFocused = true
                    }
            }
            .frame(height: Row.height)
        }
        .onChange(of: fieldFocused) { _, focused in
            model.isEditing = focused
        }
    }

    @ViewBuilder
    private var headerLink: some View {
        if model.needsPlan {
            Button { model.openPlanner() } label: {
                Label("Plan your day", systemImage: "sun.max.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.accent)
            .padding(.bottom, 8)
            .help("Pick up to 3 for today")
        } else {
            Button { model.openTasksWindow?() } label: {
                Label("All tasks", systemImage: "arrow.up.right").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.bottom, 8)
            .help("Open the board, planner and lists")
        }
    }
}

private struct EventRow: View {
    let event: TimedEvent
    let model: NotchModel

    var body: some View {
        let minutes = max(1, Int((event.start.timeIntervalSince(model.now) / 60).rounded(.up)))
        let soon = minutes <= 15
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 14))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 24, height: 24)
            Text(event.title)
                .font(.system(size: 15))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(soon ? "in \(minutes)m" : StatusEngine.timeLabel(for: event, at: model.now, calendar: .current))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(soon ? Ink.primary : Ink.secondary)
        }
        .frame(height: Row.height)
        .accessibilityElement(children: .combine)
    }
}

private struct NotchTaskRow: View {
    let task: NotchCore.TaskItem
    let model: NotchModel
    @State private var hovering = false

    var body: some View {
        let store = model.tasks
        let blocked = store.isBlocked(task.id)

        HStack(spacing: 10) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.isDone ? Ink.accent : (hovering ? Ink.secondary : Ink.tertiary))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark \(task.title) as not done" : "Complete \(task.title)")

            Text(task.title)
                .font(.system(size: 15))
                .foregroundStyle(task.isDone || blocked ? Ink.tertiary : Ink.primary)
                .strikethrough(task.isDone, color: Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if !task.isDone { meta(blocked: blocked) }
        }
        .frame(height: Row.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(task.isDone ? "Mark as Not Done" : "Complete") { store.toggle(task.id) }
            if TaskRules.isRinging(task, now: model.now) {
                Button("Snooze 10 Minutes") { store.snoozeReminder(task.id) }
                Button("Dismiss Reminder") { store.dismissReminder(task.id) }
            }
            if !task.isDone {
                Button("Focus on This") { model.startFocus(task: task.id) }
                if task.status != .doing {
                    Button("Start Doing") { store.move(task.id, to: .doing) }
                }
            }
            Divider()
            Button("Open in Tasks") { model.openTasksWindow?() }
        }
    }

    /// One fact per row, the most pressing: ringing (with its time), doing, waiting, late, due time, subtasks.
    @ViewBuilder
    private func meta(blocked: Bool) -> some View {
        let calendar = Calendar.current
        let late = TaskRules.isOverdue(task, now: model.now, calendar: calendar)
        Group {
            if TaskRules.isRinging(task, now: model.now) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.fill")
                    if let due = task.due {
                        Text(late ? TaskRules.lateness(due, now: model.now, calendar: calendar)
                                  : TaskRules.dueLabel(due, now: model.now, calendar: calendar))
                    }
                }
                .foregroundStyle(late ? Ink.late : Ink.accent)
                .accessibilityLabel("Reminder ringing")
            } else if task.status == .doing {
                Text("Doing").foregroundStyle(Ink.accent)
            } else if blocked {
                Image(systemName: "lock.fill").foregroundStyle(Ink.tertiary)
                    .accessibilityLabel("Waiting on another task")
            } else if let due = task.due, late {
                Text(TaskRules.lateness(due, now: model.now, calendar: calendar)).foregroundStyle(Ink.late)
            } else if let due = task.due, due.hasTime {
                Text(TimeText.clock(due.date, calendar: calendar)).foregroundStyle(Ink.secondary)
            } else if let progress = model.tasks.subtaskProgress(of: task.id) {
                Text("\(progress.done)/\(progress.total)").foregroundStyle(Ink.tertiary)
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
    }
}

// MARK: - Shared

private enum Row {
    static let height: CGFloat = 30
}

private struct ColumnLabel: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count, count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Ink.tertiary)
        .padding(.bottom, 8)
    }
}

/// Right-click anywhere on the open notch.
private struct AppMenu: View {
    let model: NotchModel
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let guardSettings = model.distractionSettings
        Menu(model.browsersWithoutAccess.isEmpty ? "Focus Guard" : "Focus Guard ⚠︎") {
            Button(guardSettings.enabled ? "Turn Off Nudges" : "Nudge Me Back to Work") {
                model.distractionSettings.enabled.toggle()
            }
            if guardSettings.enabled, !model.browsersWithoutAccess.isEmpty {
                let names = model.browsersWithoutAccess.sorted().joined(separator: " and ")
                Button("Can't see sites in \(names): Allow in System Settings…") {
                    Browser.openAutomationSettings()
                }
            }
            Divider()
            Section("Counts as a distraction") {
                ForEach(DistractionKind.allCases, id: \.self) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { model.distractionSettings.kinds.contains(kind) },
                        set: { on in
                            if on { model.distractionSettings.kinds.insert(kind) } else { model.distractionSettings.kinds.remove(kind) }
                        }
                    ))
                }
            }
            Section("Nudge after") {
                ForEach(NotchModel.Strictness.allCases, id: \.self) { preset in
                    Toggle(preset.label, isOn: Binding(
                        get: { NotchModel.Strictness.matching(model.distractionSettings) == preset },
                        set: { _ in preset.apply(to: &model.distractionSettings) }
                    ))
                }
            }
        }
        Divider()
        Button(opensAtLogin ? "Don't Open at Login" : "Open at Login") {
            do {
                if opensAtLogin {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSSound.beep()
            }
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
        Divider()
        Button("Quit Notch") { NSApp.terminate(nil) }
    }
}
