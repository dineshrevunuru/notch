import AppKit
import NotchCore
import Observation
import SwiftUI

/// Left of the camera: what's up next, in the default text color.
enum LeftSignal: Equatable {
    enum Urgency: Equatable { case normal, late, ringing }
    /// The next task, with its time when it has one.
    case nextTask(title: String, time: String?, urgency: Urgency)
    /// The next meeting today, when it comes before the next timed task.
    case nextMeeting(title: String, time: String, minutes: Int)
    /// In focus mode: what you're working on, or the rounds if you didn't pick a task.
    case focusTask(title: String)
    case focusRounds(round: Int, rounds: Int)
}

/// Right of the camera: what's happening now, in the active color (orange in focus mode).
enum RightSignal: Equatable {
    case timer(phase: PomodoroTimer.Phase, remaining: TimeInterval, progress: Double, paused: Bool)
    case meeting(title: String, minutesLeft: Int)
    /// A card in the board's Doing column. `others` counts the rest of Doing.
    case doing(title: String, others: Int)
}

@Observable
final class NotchModel {
    let tasks: TaskStore
    let calendar: CalendarStore
    let pomodoro: PomodoroTimer

    var isExpanded = false
    /// True while a text field in the open notch has focus; the notch stays open so typing isn't cut off.
    var isEditing = false
    private(set) var now = Date()
    /// Pins the clock for preview renders, so a screenshot shows the same time on every run.
    /// Nil, the real time, everywhere else.
    static var fixedNow: Date?
    private(set) var currentAlert: NotchAlert?
    /// The task a focus session is about, if you picked one.
    private(set) var focusTaskID: UUID?

    /// Your working hours, for the planner's free-time check and its prompts.
    var workday: Workday = NotchModel.savedWorkday {
        didSet {
            UserDefaults.standard.set(workday.startHour, forKey: "workdayStart")
            UserDefaults.standard.set(workday.endHour, forKey: "workdayEnd")
        }
    }
    /// Which list the task window should switch to the next time it shows.
    var requestedList: TaskList?

    /// Focus Guard: nudges back to work. Off unless turned on.
    var distractionSettings: DistractionSettings = NotchModel.savedDistractionSettings {
        didSet { Self.save(distractionSettings) }
    }
    /// Browsers macOS won't let Focus Guard ask for their tab address. Shown in the Focus Guard
    /// menu with a way to fix it, instead of failing silently.
    var browsersWithoutAccess: Set<String> = []
    @ObservationIgnored private var watch = DistractionWatch()
    @ObservationIgnored private var distractionSegment: (source: DistractionSource, start: Date)?

    /// Set by the app: open the full task window / open the notch.
    @ObservationIgnored var openTasksWindow: (() -> Void)?
    @ObservationIgnored var expandNotch: (() -> Void)?

    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var lastReloadMinute = -1
    @ObservationIgnored private var alertQueue: [NotchAlert] = []
    @ObservationIgnored private var seenAlerts: Set<String> = []
    @ObservationIgnored private var alertDeadline: Date?
    @ObservationIgnored private var peekHovered = false

    init(tasks: TaskStore = TaskStore(), calendar: CalendarStore = CalendarStore(), pomodoro: PomodoroTimer? = nil) {
        self.tasks = tasks
        self.calendar = calendar
        self.pomodoro = pomodoro ?? PomodoroTimer(plan: Self.savedPlan)
    }

    // MARK: Calendar-derived state

    var status: DayStatus {
        StatusEngine.status(at: now, events: calendar.events, calendar: .current)
    }

    var upcoming: [TimedEvent] {
        StatusEngine.upcoming(at: now, events: calendar.events, limit: 4)
    }

    // MARK: Glance signals

    var isFocusing: Bool { pomodoro.phase == .focus }

    // MARK: Planner

    var todayKey: String { Planner.dayKey(now, calendar: .current) }
    var todayPlan: DayPlan? { tasks.plan(for: todayKey) }

    /// Today's picks, in the order chosen.
    var todayPicks: [TaskItem] {
        (todayPlan?.taskIDs ?? []).compactMap(tasks.task)
    }

    /// True on a workday, during working hours, before today has a plan.
    var needsPlan: Bool {
        guard todayPlan == nil, Planner.isWorkday(now, calendar: .current) else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= workday.startHour && hour < workday.endHour - 1
    }

    var dayTime: (free: Int, meetings: Int) {
        Planner.time(on: now, workday: workday, events: calendar.events, calendar: .current)
    }

    // MARK: Focus Guard

    /// When nudges apply: a focus round always; otherwise only during your workday, never on a break.
    var distractionContext: DistractionWatch.Context {
        guard distractionSettings.enabled else { return .off }
        if isFocusing { return .focus }
        if pomodoro.phase?.isBreak == true { return .off }
        guard Planner.isWorkday(now, calendar: .current) else { return .off }
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= workday.startHour && hour < workday.endHour ? .workday : .off
    }

    /// One look at the front app, from the monitor.
    func observeDistraction(_ source: DistractionSource?) {
        let current = Date()
        if distractionSegment?.source != source {
            if let segment = distractionSegment {
                tasks.logDistraction(segment.source, start: segment.start, end: current)
            }
            distractionSegment = source.map { ($0, current) }
        }
        if let nudge = watch.observe(source, at: current, context: distractionContext, settings: distractionSettings) {
            enqueue([.nudge(nudge, at: current)])
            restartClock()
        }
    }

    func snoozeNudges(minutes: Int) {
        watch.quiet(until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        dismissAlert()
    }

    private static var savedDistractionSettings: DistractionSettings {
        let defaults = UserDefaults.standard
        let kinds = (defaults.stringArray(forKey: "distractionKinds") ?? ["game", "video"]).compactMap(DistractionKind.init(rawValue:))
        var settings = DistractionSettings(enabled: defaults.bool(forKey: "distractionEnabled"), kinds: Set(kinds))
        Strictness(rawValue: defaults.string(forKey: "distractionStrictness") ?? "")?.apply(to: &settings)
        return settings
    }

    private static func save(_ settings: DistractionSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.enabled, forKey: "distractionEnabled")
        defaults.set(settings.kinds.map(\.rawValue).sorted(), forKey: "distractionKinds")
        defaults.set(Strictness.matching(settings).rawValue, forKey: "distractionStrictness")
    }

    /// The three presets offered: Balanced is 15 min in the workday and 1 min in a focus round.
    enum Strictness: String, CaseIterable {
        case gentle, balanced, strict

        var label: String {
            switch self {
            case .gentle: "Gentle: 30 min"
            case .balanced: "Balanced: 15 min, 1 min in focus"
            case .strict: "Strict: 5 min"
            }
        }

        func apply(to settings: inout DistractionSettings) {
            switch self {
            case .gentle: settings.workdayThreshold = 30 * 60; settings.focusThreshold = 5 * 60
            case .balanced: settings.workdayThreshold = 15 * 60; settings.focusThreshold = 60
            case .strict: settings.workdayThreshold = 5 * 60; settings.focusThreshold = 60
            }
        }

        static func matching(_ settings: DistractionSettings) -> Strictness {
            allCases.first { preset in
                var copy = settings
                preset.apply(to: &copy)
                return copy == settings
            } ?? .balanced
        }
    }

    func openPlanner() {
        requestedList = .planner
        openTasksWindow?()
    }

    private static var savedWorkday: Workday {
        let defaults = UserDefaults.standard
        let start = defaults.object(forKey: "workdayStart") as? Int ?? 9
        let end = defaults.object(forKey: "workdayEnd") as? Int ?? 18
        return Workday(startHour: start, endHour: end)
    }

    /// The focus task while it's still open.
    var focusTask: TaskItem? {
        focusTaskID.flatMap(tasks.task).flatMap { $0.isDone ? nil : $0 }
    }

    /// The card that leads the open panel: the first in Doing, unless a break timer or a meeting
    /// you're in leads instead.
    var nowTask: TaskItem? {
        if pomodoro.isActive || StatusEngine.current(at: now, events: calendar.events) != nil { return nil }
        return doingTasks.first
    }

    /// The open panel's list, already cut to what fits.
    struct Agenda {
        let items: [AgendaItem]
        let shown: [AgendaItem]
        /// Items that didn't fit; shown as one "N more" row.
        let hidden: Int
        /// Finished today, shown only in room left over.
        let done: [TaskItem]

        var rowCount: Int { max(1, shown.count + (hidden > 0 ? 1 : 0) + done.count) }
    }

    static let agendaMaxRows = 4

    var agenda: Agenda {
        let calendar = Calendar.current
        let items = TaskRules.agenda(tasks.tasks, events: self.calendar.events, now: now, calendar: calendar, excluding: nowTask?.id)
        let shown = Array(items.prefix(items.count > Self.agendaMaxRows ? Self.agendaMaxRows - 1 : Self.agendaMaxRows))
        let hidden = items.count - shown.count
        let startOfToday = calendar.startOfDay(for: now)
        let room = max(0, Self.agendaMaxRows - shown.count - (hidden > 0 ? 1 : 0))
        let done = tasks.tasks
            .filter { ($0.completedAt ?? .distantPast) >= startOfToday && $0.parentID == nil }
            .sorted { ($0.completedAt ?? now) > ($1.completedAt ?? now) }
            .prefix(room)
        return Agenda(items: items, shown: shown, hidden: hidden, done: Array(done))
    }

    /// The open panel is as tall as what it holds, so it never covers more of the screen than it needs.
    var openHeight: CGFloat {
        if isFocusing { return 300 }
        return min(NotchMetrics.maxOpenHeight, 204 + CGFloat(agenda.rowCount) * 30)
    }

    /// The board's Doing column, oldest start first.
    var doingTasks: [TaskItem] {
        tasks.tasks
            .filter { !$0.isDone && $0.status == .doing && $0.parentID == nil }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    var leftSignal: LeftSignal? {
        let calendar = Calendar.current
        if isFocusing {
            if let task = focusTask { return .focusTask(title: task.title) }
            return .focusRounds(round: pomodoro.round ?? 1, rounds: pomodoro.plan.rounds)
        }
        switch TaskRules.upNext(tasks.tasks, events: self.calendar.events, now: now, calendar: calendar) {
        case .meeting(let event):
            return .nextMeeting(
                title: event.title,
                time: TimeText.compactClock(event.start, calendar: calendar),
                minutes: minutesUntil(event.start)
            )
        case .task(let task, let urgency):
            let mapped: LeftSignal.Urgency = switch urgency {
            case .normal: .normal
            case .late: .late
            case .ringing: .ringing
            }
            return .nextTask(title: task.title, time: timeLabel(task, calendar: calendar), urgency: mapped)
        case nil:
            return nil
        }
    }

    private func timeLabel(_ task: TaskItem, calendar: Calendar) -> String? {
        guard let due = task.due, due.hasTime, !TaskRules.isOverdue(task, now: now, calendar: calendar) else { return nil }
        return TimeText.compactClock(due.date, calendar: calendar)
    }

    var rightSignal: RightSignal? {
        if let phase = pomodoro.phase {
            return .timer(
                phase: phase,
                remaining: pomodoro.remaining(at: now) ?? 0,
                progress: pomodoro.progress(at: now) ?? 0,
                paused: pomodoro.isPaused
            )
        }
        if let current = StatusEngine.current(at: now, events: calendar.events) {
            return .meeting(title: current.title, minutesLeft: minutesUntil(current.end))
        }
        let doing = doingTasks
        if let first = doing.first {
            return .doing(title: first.title, others: doing.count - 1)
        }
        return nil
    }

    /// For focus mode: the meeting you're in, or the next one today, so focus never runs into it blind.
    var focusCalendarNote: String? {
        let calendar = Calendar.current
        if let current = StatusEngine.current(at: now, events: self.calendar.events) {
            return "In \(current.title) until \(TimeText.clock(current.end, calendar: calendar))"
        }
        guard let next = StatusEngine.upcoming(at: now, events: self.calendar.events, limit: 1).first,
              calendar.isDate(next.start, inSameDayAs: now) else { return nil }
        return "Next: \(next.title) at \(TimeText.clock(next.start, calendar: calendar))"
    }

    var showsWings: Bool { leftSignal != nil || rightSignal != nil }

    /// True while the pointer is over a wing in the menu bar: the wing steps aside so the app
    /// menu underneath can be seen and clicked.
    private(set) var wingsRetracted = false

    func setWingsRetracted(_ retracted: Bool) {
        guard retracted != wingsRetracted else { return }
        withAnimation(Motion.morph) { wingsRetracted = retracted }
    }

    var presentation: NotchPresentation {
        if isExpanded { return .open(height: openHeight) }
        if currentAlert != nil { return .peek }
        return .closed(wings: showsWings && !wingsRetracted)
    }

    /// The notch's task column: what you're doing, what else needs you today, then what you finished today.
    var todayTasks: [TaskItem] {
        let calendar = Calendar.current
        let doing = doingTasks
        let open = doing + TaskRules.today(tasks.tasks, now: now, calendar: calendar).filter { $0.status != .doing }
        let startOfToday = calendar.startOfDay(for: now)
        let doneToday = tasks.tasks
            .filter { task in
                guard let done = task.completedAt, done >= startOfToday, let due = task.due else { return false }
                return calendar.startOfDay(for: due.date) <= startOfToday
            }
            .sorted { ($0.completedAt ?? now) < ($1.completedAt ?? now) }
        return open + doneToday
    }

    // MARK: Actions

    func start() {
        calendar.start()
        restartClock()
    }

    // MARK: Pomodoro

    /// Starts the next focus round. A task attached here carries over to later rounds until it's done.
    func startFocus(minutes: Int? = nil, task: UUID? = nil) {
        if let task {
            focusTaskID = task
            // Focusing on a card means you've started it.
            if tasks.task(task)?.status != .doing { tasks.move(task, to: .doing) }
        } else if focusTask == nil {
            focusTaskID = doingTasks.first?.id
        }
        if pomodoro.phase == .focus, task != nil { return } // already focusing: just switch the task
        pomodoro.startFocus(minutes: minutes)
        dismissPomodoroAlerts()
        restartClock()
    }

    func setFocusTask(_ id: UUID?) {
        focusTaskID = id
        if let id, tasks.task(id)?.status != .doing { tasks.move(id, to: .doing) }
    }

    func togglePause() {
        if pomodoro.isPaused { pomodoro.resume() } else { pomodoro.pause() }
        restartClock()
    }

    func skipPhase() {
        logFocusSoFar()
        pomodoro.skip()
        restartClock()
    }

    func stopFocus() {
        logFocusSoFar()
        pomodoro.stop()
        focusTaskID = nil
        restartClock()
    }

    /// Records the focus time of a round that's being cut short. Pauses don't count.
    private func logFocusSoFar() {
        let current = Date()
        switch pomodoro.state {
        case .running(.focus, _, let start, let end):
            tasks.logFocus(start: start, end: min(current, end), task: focusTask?.id)
        case .paused(.focus, _, let remaining, let total):
            tasks.logFocus(start: current.addingTimeInterval(remaining - total), end: current, task: focusTask?.id)
        default:
            break
        }
    }

    func setPlan(_ plan: PomodoroTimer.Plan) {
        pomodoro.plan = plan
        UserDefaults.standard.set(plan.name, forKey: Self.planKey)
    }

    private static let planKey = "pomodoroPlan"

    private static var savedPlan: PomodoroTimer.Plan {
        let name = UserDefaults.standard.string(forKey: planKey)
        return PomodoroTimer.Plan.all.first { $0.name == name } ?? .classic
    }

    /// Starting a round from a banner or the panel makes any session banner still showing stale.
    private func dismissPomodoroAlerts() {
        alertQueue.removeAll { if case .breakEnded = $0 { true } else if case .focusEnded = $0 { true } else { false } }
        switch currentAlert {
        case .breakEnded, .focusEnded: dismissAlert()
        default: break
        }
    }

    func refreshNow() {
        tasks.reloadIfChangedOnDisk()
        tick()
    }

    /// Quick add from the notch: lands in the Inbox, due today, so it shows in the list you're looking at.
    func addTodayTask(_ title: String) {
        tasks.add(title, due: .day(now))
    }

    // MARK: Alerts

    func setPeekHovered(_ hovered: Bool) {
        guard hovered != peekHovered else { return }
        peekHovered = hovered
        // Give a moment to read after the pointer leaves, instead of vanishing under it.
        if !hovered, currentAlert != nil { alertDeadline = Date().addingTimeInterval(2.5) }
    }

    /// For `--render-previews` only: shows a banner immediately.
    func showPreviewAlert(_ alert: NotchAlert) {
        currentAlert = alert
        alertDeadline = now.addingTimeInterval(alert.lingers)
    }

    func dismissAlert() {
        guard currentAlert != nil else { return }
        withAnimation(Motion.close) { currentAlert = nil }
        alertDeadline = nil
        peekHovered = false
        restartClock()
    }

    /// Opening the notch shows everything at once, so pending banners are dropped.
    func clearAlertsForExpand() {
        alertQueue.removeAll()
        currentAlert = nil
        alertDeadline = nil
        peekHovered = false
    }

    func completeFromAlert(_ id: UUID) {
        tasks.complete(id)
        dismissAlert()
    }

    func snoozeFromAlert(_ id: UUID) {
        tasks.snoozeReminder(id, minutes: 10)
        dismissAlert()
    }

    func dismissReminderFromAlert(_ id: UUID) {
        tasks.dismissReminder(id)
        dismissAlert()
    }

    private func enqueue(_ alerts: [NotchAlert]) {
        // While the notch is open you're already looking at everything.
        guard !isExpanded else { return }
        alertQueue.append(contentsOf: alerts)
    }

    private func advanceAlerts() {
        if currentAlert != nil, !peekHovered, let deadline = alertDeadline, now >= deadline {
            dismissAlert()
            return // leave a beat before the next one drops
        }
        guard currentAlert == nil, !isExpanded else { return }

        // Focus mode holds task banners until the break; they wait in the queue, in order.
        var index = 0
        while index < alertQueue.count {
            let next = alertQueue[index]
            if !isStillRelevant(next) {
                alertQueue.remove(at: index)
                continue
            }
            if isFocusing && AlertPlanner.isHeldDuringFocus(next) {
                index += 1
                continue
            }
            alertQueue.remove(at: index)
            withAnimation(Motion.open) { currentAlert = next }
            alertDeadline = now.addingTimeInterval(next.lingers)
            sound(for: next)?.play()
            return
        }
    }

    private func isStillRelevant(_ alert: NotchAlert) -> Bool {
        switch alert {
        case .reminder(let id, _, _):
            return tasks.task(id).map { TaskRules.isRinging($0, now: now) } ?? false
        case .due(let id, _, _):
            return tasks.task(id).map { !$0.isDone } ?? false
        case .eventSoon(_, _, let start):
            return start > now
        case .reminders:
            return true
        case .focusEnded:
            return pomodoro.phase?.isBreak == true
        case .breakEnded:
            if case .ready = pomodoro.state { return true }
            return false
        case .planDay(let day):
            return tasks.plan(for: day) == nil
        case .wrapUpDay(let day):
            return tasks.plan(for: day).map { !$0.isClosed } ?? false
        case .nudge:
            return distractionSegment != nil
        }
    }

    private func sound(for alert: NotchAlert) -> NSSound? {
        switch alert {
        case .reminder, .reminders, .due: NSSound(named: "Ping")
        case .eventSoon: NSSound(named: "Tink")
        case .focusEnded: NSSound(named: "Glass")
        case .breakEnded: NSSound(named: "Bottle")
        case .planDay, .wrapUpDay: NSSound(named: "Tink")
        case .nudge: NSSound(named: "Pop")
        }
    }

    // MARK: Clock

    /// Ticks every second while something counts down on screen; otherwise on the minute,
    /// or exactly when the next reminder, deadline or event alert is due, whichever is sooner.
    private func restartClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(self.secondsUntilNextTick()))
            }
        }
    }

    private func tick() {
        now = Self.fixedNow ?? Date()
        let roundInProgress: (start: Date, end: Date)? = {
            if case .running(.focus, _, let start, let end) = pomodoro.state { return (start, end) }
            return nil
        }()
        if let event = pomodoro.advance(to: now) {
            if case .focusEnded = event, let round = roundInProgress {
                tasks.logFocus(start: round.start, end: round.end, task: focusTask?.id)
            }
            let rounds = pomodoro.plan.rounds
            let alert: NotchAlert = switch event {
            case .focusEnded(let round, let breakPhase, let minutes):
                .focusEnded(round: round, rounds: rounds, breakMinutes: minutes, isLongBreak: breakPhase == .longBreak, at: now)
            case .breakEnded(let next):
                .breakEnded(nextRound: next, rounds: rounds, at: now)
            }
            enqueue([alert])
            // With the panel open there's no banner, so the chime alone marks the change.
            if isExpanded { sound(for: alert)?.play() }
        }

        let minute = Int(now.timeIntervalSince1970 / 60)
        if minute != lastReloadMinute {
            lastReloadMinute = minute
            calendar.reload(now: now)
            tasks.reloadIfChangedOnDisk()
        }

        let plan = AlertPlanner.plan(now: now, tasks: tasks.tasks, events: calendar.events, seen: seenAlerts)
        seenAlerts.formUnion(plan.consumed)
        enqueue(plan.alerts)
        if let prompt = Planner.prompt(now: now, workday: workday, plan: todayPlan, calendar: .current),
           !seenAlerts.contains(prompt.id) {
            seenAlerts.insert(prompt.id)
            enqueue([prompt])
        }
        advanceAlerts()
    }

    private func secondsUntilNextTick() -> Double {
        let current = Date()
        let t = current.timeIntervalSince1970
        // Held banners don't need a fast tick; the break that releases them comes with its own.
        let waiting = alertQueue.contains { !(isFocusing && AlertPlanner.isHeldDuringFocus($0)) }
        if pomodoro.isRunning || currentAlert != nil || waiting {
            return 1 - t.truncatingRemainder(dividingBy: 1) + 0.01
        }
        var wait = 60 - t.truncatingRemainder(dividingBy: 60) + 0.05
        if let next = nextAlertMoment(after: current) {
            wait = min(wait, max(0.05, next.timeIntervalSince(current) + 0.05))
        }
        return wait
    }

    private func nextAlertMoment(after date: Date) -> Date? {
        var moments: [Date] = []
        for task in tasks.tasks where !task.isDone {
            if let at = task.alertTime, !task.reminderHandled, at > date { moments.append(at) }
            if let due = task.due, due.hasTime, due.date > date { moments.append(due.date) }
        }
        for event in calendar.events {
            let drop = event.start.addingTimeInterval(-AlertPlanner.eventLead)
            if drop > date { moments.append(drop) }
        }
        return moments.min()
    }

    private func minutesUntil(_ date: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    }
}
