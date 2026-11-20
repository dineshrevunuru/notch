import AppKit
import NotchCore
import SwiftUI

/// `Notch --render-previews <dir>` draws every state of the notch and the task window to PNGs
/// and exits, so the look can be reviewed without hovering. Sample data only: it never reads or
/// writes your calendar or your task file.
enum PreviewRenderer {
    static func run(into directory: URL) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NotchModel.fixedNow = now

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metrics = NotchMetrics.current()
            for (name, model) in notchScenarios() {
                try renderNotch(model: model, metrics: metrics, to: directory.appendingPathComponent("\(name).png"))
                print("rendered \(name).png")
            }
            try renderWindow(model: sampleModel(events: laterEvents(), tasks: richTasks()), to: directory.appendingPathComponent("w1-task-window.png"))
            print("rendered w1-task-window.png")

            let store = richTasks()
            let jobSearch = store.project(named: "Work")!.id
            try renderWindow(
                model: sampleModel(events: laterEvents(), tasks: store),
                list: .project(jobSearch),
                selectedTask: store.tasks.first { $0.title == "Publish and share the case study" }!.id,
                size: CGSize(width: 1120, height: 1180),
                to: directory.appendingPathComponent("w2-project-with-inspector.png")
            )
            print("rendered w2-project-with-inspector.png")

            let boardStore = richTasks()
            for title in ["Ship the case study", "Send the November invoice"] {
                if let id = boardStore.tasks.first(where: { $0.title == title })?.id { boardStore.move(id, to: .doing, now: minutes(-45)) }
            }
            if let id = boardStore.tasks.first(where: { $0.title == "Book the dentist" })?.id { boardStore.move(id, to: .done, now: minutes(-20)) }
            try renderWindow(
                model: sampleModel(events: laterEvents(), tasks: boardStore),
                list: .board,
                to: directory.appendingPathComponent("w3-board.png")
            )
            print("rendered w3-board.png")

            // Planner, morning: one late task to settle, a meeting, two picks made. A fresh plan
            // starts from what's already in Doing today, so moving two cards there picks them.
            let morning = richTasks()
            for (title, estimate) in [("Ship the case study", 90), ("Send the November invoice", 30)] {
                guard let id = morning.tasks.first(where: { $0.title == title })?.id else { continue }
                morning.setEstimate(id, minutes: estimate)
                morning.move(id, to: .doing, now: minutes(-20))
            }
            try renderWindow(
                model: sampleModel(events: laterEvents(), tasks: morning),
                list: .planner,
                size: CGSize(width: 1120, height: 1100),
                to: directory.appendingPathComponent("w4-planner-morning.png")
            )
            print("rendered w4-planner-morning.png")

            // Planner, during the day: three picks with estimates, one done, focus time logged.
            let day = richTasks()
            let titles = ["Ship the case study", "Send the November invoice", "Book the dentist"]
            let ids = titles.compactMap { t in day.tasks.first { $0.title == t }?.id }
            for (id, est) in zip(ids, [90, 30, 15]) { day.setEstimate(id, minutes: est) }
            day.savePlan(day: Planner.dayKey(now, calendar: calendar), picks: ids, now: minutes(-240))
            day.complete(ids[2], now: minutes(-60))
            day.logFocus(start: minutes(-200), end: minutes(-175), task: ids[0])
            day.logFocus(start: minutes(-170), end: minutes(-145), task: ids[0])
            try renderWindow(
                model: sampleModel(events: laterEvents(), tasks: day),
                list: .planner,
                size: CGSize(width: 1120, height: 860),
                to: directory.appendingPathComponent("w5-planner-day.png")
            )
            print("rendered w5-planner-day.png")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Preview render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: Sample data

    /// The time every scene is drawn at. App Store renders (`--store`) use 1:30 PM today, so the
    /// planner has a working afternoon to fill; otherwise it's the moment you run it.
    private static let now: Date = CommandLine.arguments.contains("--store")
        ? Calendar.current.date(bySettingHour: 13, minute: 30, second: 0, of: Date())!
        : Date()
    private static func minutes(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }
    private static let calendar = Calendar.current

    private static func laterEvents() -> [TimedEvent] {
        let tomorrowMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now)!)!
        return [
            TimedEvent(id: "a", title: "Weekly sync", start: minutes(35), end: minutes(65)),
            TimedEvent(id: "b", title: "Design review", start: minutes(190), end: minutes(220)),
            TimedEvent(id: "c", title: "Standup", start: tomorrowMorning, end: tomorrowMorning.addingTimeInterval(900)),
        ]
    }

    private static func emptyStore() -> TaskStore {
        TaskStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("notch-preview-\(UUID().uuidString).json"),
            legacyFileURL: nil
        )
    }

    /// A believable spread: overdue, due today, a ringing reminder, subtasks, a dependency, a repeat.
    private static func richTasks() -> TaskStore {
        let store = emptyStore()
        let job = store.addProject("Work")!
        let client = store.addProject("Client")!
        _ = store.addProject("Portfolio")

        var follow = store.add("Follow up on the proposal", project: job.id, now: minutes(-600))!
        follow.due = .day(calendar.date(byAdding: .day, value: -2, to: now)!)
        follow.priority = .high
        store.update(follow)

        var invoice = store.add("Send the November invoice", project: client.id, now: minutes(-500))!
        invoice.due = DueDate(date: minutes(150), hasTime: true)
        invoice.reminder = minutes(-3)
        invoice.tags = ["finance"]
        store.update(invoice)

        var caseStudy = store.add("Ship the case study", project: job.id, now: minutes(-400))!
        caseStudy.due = .day(now)
        caseStudy.priority = .medium
        store.update(caseStudy)
        let draft = store.add("Draft the outline", parent: caseStudy.id, now: minutes(-390))!
        store.add("Pick three screens", parent: caseStudy.id, now: minutes(-380))
        store.complete(draft.id, now: minutes(-60))

        var publish = store.add("Publish and share the case study", project: job.id, now: minutes(-300))!
        publish.due = .day(calendar.date(byAdding: .day, value: 2, to: now)!)
        store.update(publish)
        store.addDependency(publish.id, blockedBy: caseStudy.id)

        var review = store.add("Weekly review", now: minutes(-200))!
        review.due = .day(calendar.date(byAdding: .day, value: 1, to: now)!)
        review.recurrence = Recurrence(unit: .week)
        store.update(review)

        store.add("Book the dentist", now: minutes(-100))
        return store
    }

    private enum Session {
        case focus(round: Int, minutesLeft: Double)
        case paused(round: Int, minutesLeft: Double)
        case breakTime(round: Int, minutesLeft: Double)
    }

    private static func sampleModel(
        access: CalendarStore.Access = .granted,
        events: [TimedEvent] = [],
        tasks: TaskStore = emptyStore(),
        session: Session? = nil,
        focusOn: String? = nil,
        expanded: Bool = false
    ) -> NotchModel {
        let timer = PomodoroTimer(plan: .classic)
        // Walk the timer through real transitions so every state is one it can actually reach.
        func reach(round: Int, at start: Date) {
            var t = start.addingTimeInterval(-Double(round - 1) * 30 * 60)
            for _ in 1..<round {
                timer.startFocus(now: t)
                t = t.addingTimeInterval(25 * 60)
                timer.advance(to: t)              // focus → short break
                t = t.addingTimeInterval(5 * 60)
                timer.advance(to: t)              // break → ready for the next round
            }
            timer.startFocus(now: t)
        }
        switch session {
        case .focus(let round, let left):
            reach(round: round, at: minutes(left - 25))
        case .paused(let round, let left):
            reach(round: round, at: minutes(left - 25))
            timer.pause(now: now)
        case .breakTime(let round, let left):
            reach(round: round, at: minutes(left - 5 - 25))
            timer.advance(to: minutes(left - 5))  // focus ended, break running
        case nil:
            break
        }
        let model = NotchModel(tasks: tasks, calendar: CalendarStore(previewAccess: access, events: events), pomodoro: timer)
        if let title = focusOn { model.setFocusTask(tasks.tasks.first { $0.title == title }?.id) }
        model.isExpanded = expanded
        model.refreshNow()
        return model
    }

    private static func notchScenarios() -> [(String, NotchModel)] {
        let busy = [TimedEvent(id: "n", title: "Design review", start: minutes(-6), end: minutes(24))] + laterEvents()

        let todayOnly = emptyStore()
        if var t = todayOnly.add("Pick three screens") { t.due = .day(now); todayOnly.update(t) }
        if var t = todayOnly.add("Reply to the client") { t.due = .day(now); todayOnly.update(t) }

        let overdue = emptyStore()
        if var t = overdue.add("Follow up on the proposal") { t.due = .day(calendar.date(byAdding: .day, value: -1, to: now)!); overdue.update(t) }

        func settled(_ model: NotchModel) -> NotchModel {
            // Any banner has already come and gone; what's left is the glance.
            model.dismissAlert()
            return model
        }

        // A fresh list per scenario: focusing on a task moves it to Doing, which must not leak into others.
        func timedTodayStore() -> TaskStore {
            let store = emptyStore()
            if var t = store.add("Landing page hero") { t.due = DueDate(date: minutes(150), hasTime: true); store.update(t) }
            if var t = store.add("Prepare the interview deck") { t.due = .day(now); store.update(t) }
            return store
        }
        let soonMeeting = [TimedEvent(id: "s", title: "Weekly sync", start: minutes(7), end: minutes(37))]
        let hero = "Landing page hero"

        return [
            ("01-open", sampleModel(events: busy, tasks: richTasks(), expanded: true)),
            ("02-open-focus-mode", sampleModel(events: laterEvents(), tasks: timedTodayStore(), session: .focus(round: 2, minutesLeft: 18.4), focusOn: hero, expanded: true)),
            ("03-open-focus-no-task", sampleModel(events: laterEvents(), tasks: timedTodayStore(), session: .paused(round: 1, minutesLeft: 11.2), expanded: true)),
            ("04-open-break", sampleModel(events: laterEvents(), tasks: timedTodayStore(), session: .breakTime(round: 2, minutesLeft: 3.5), expanded: true)),
            ("05-wings-up-next", settled(sampleModel(tasks: timedTodayStore()))),
            ("06-wings-late-and-meeting", settled(sampleModel(events: busy, tasks: overdue))),
            ("07-wings-meeting-soon", settled(sampleModel(events: soonMeeting, tasks: timedTodayStore()))),
            ("08-wings-focus-task", sampleModel(events: laterEvents(), tasks: timedTodayStore(), session: .focus(round: 2, minutesLeft: 18.4), focusOn: hero)),
            ("09-wings-focus-rounds", settled(sampleModel(tasks: timedTodayStore(), session: .focus(round: 3, minutesLeft: 6)))),
            ("10-wings-break", settled(sampleModel(tasks: timedTodayStore(), session: .breakTime(round: 2, minutesLeft: 3.5)))),
            ("11-wings-focus-paused", settled(sampleModel(tasks: timedTodayStore(), session: .paused(round: 1, minutesLeft: 11.2), focusOn: hero))),
            ("12-peek-reminder", sampleModel(tasks: richTasks())),
            ("14-wings-doing", {
                let store = emptyStore()
                if var t = store.add("Prepare the interview deck") { t.due = .day(now); store.update(t) }
                if let t = store.add("Landing page hero") { store.move(t.id, to: .doing, now: minutes(-30)) }
                return sampleModel(tasks: store)
            }()),
            ("13-peek-break-started", sampleModel(session: .focus(round: 2, minutesLeft: -0.02))),
            ("16-wings-meeting-before-task", settled(yourAfternoon(expanded: false))),
            ("18-peek-nudge-workday", {
                let model = settled(yourAfternoon(expanded: false))
                model.showPreviewAlert(.nudge(Nudge(source: DistractionSource(kind: .video, name: "YouTube"), minutes: 17, duringFocus: false), at: now))
                return model
            }()),
            ("19-peek-nudge-focus", {
                let model = sampleModel(tasks: timedTodayStore(), session: .focus(round: 2, minutesLeft: 14.3), focusOn: hero)
                model.showPreviewAlert(.nudge(Nudge(source: DistractionSource(kind: .social, name: "Reddit"), minutes: 1, duringFocus: true), at: now))
                return model
            }()),
            ("17-open-keeps-the-glance", yourAfternoon(expanded: true)),
            ("20-open-ringing-no-calendar-events", {
                // Late afternoon: one card in Doing, a 5 PM task whose reminder is ringing, two more for today.
                let store = emptyStore()
                if let t = store.add("Polish the app") { store.move(t.id, to: .doing, now: minutes(-90)) }
                if var t = store.add("Landing page hero") {
                    t.due = DueDate(date: minutes(45), hasTime: true); t.reminder = minutes(-5); store.update(t)
                }
                if var t = store.add("Prepare the deck for the pre-interview call") { t.due = .day(now); store.update(t) }
                if var t = store.add("Reply to the client") { t.due = .day(now); store.update(t) }
                let model = sampleModel(tasks: store, expanded: true)
                return model
            }()),
            ("15-peek-plan-day", {
                let model = sampleModel(events: laterEvents(), tasks: timedTodayStore())
                model.showPreviewAlert(.planDay(day: Planner.dayKey(now, calendar: calendar)))
                return model
            }()),
        ]
    }

    /// A typical afternoon: a meeting at the top of the hour, a task an hour later,
    /// one card in Doing.
    private static func yourAfternoon(expanded: Bool) -> NotchModel {
        let store = emptyStore()
        if var t = store.add("Landing page hero") { t.due = DueDate(date: minutes(160), hasTime: true); store.update(t) }
        if var t = store.add("Prepare the interview deck") { t.due = .day(now); store.update(t) }
        if let t = store.add("Polish the app") { store.move(t.id, to: .doing, now: minutes(-40)) }
        let top = Calendar.current.date(bySetting: .minute, value: 0, of: minutes(100)) ?? minutes(100)
        let meeting = [TimedEvent(id: "m", title: "Team meeting", start: top, end: top.addingTimeInterval(1800))]
        return sampleModel(events: meeting, tasks: store, expanded: expanded)
    }

    // MARK: Rendering

    /// Draws through a real NSHostingView, so AppKit-backed controls (text field, scroll view) render too.
    private static func renderNotch(model: NotchModel, metrics: NotchMetrics, to url: URL) throws {
        let size = metrics.windowFrame.size
        let scene = ZStack(alignment: .top) {
            // A stand-in for the menu bar over a warm wallpaper, so the black shape has something to sit on.
            LinearGradient(colors: [Color(white: 0.55), Color(red: 0.42, green: 0.36, blue: 0.32)],
                           startPoint: .top, endPoint: .bottom)
            Color.white.opacity(0.18).frame(height: metrics.notchSize.height)
            NotchRootView(model: model, metrics: metrics)
            // The camera housing, painted on top: on the real screen nothing under it is visible,
            // so the preview hides it too. Slightly lighter than black so its edge shows; pure
            // black with --store, for App Store screenshots, as it looks on a real Mac.
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .fill(CommandLine.arguments.contains("--store") ? Color.black : Color(white: 0.13))
                .frame(width: metrics.notchSize.width, height: metrics.notchSize.height)
        }
        .frame(width: size.width, height: size.height)
        try snapshot(scene, size: size, to: url)
    }

    private static func renderWindow(
        model: NotchModel, list: TaskList = .today, selectedTask: UUID? = nil,
        size: CGSize = CGSize(width: 1120, height: 720), to url: URL
    ) throws {
        let controller = NSHostingController(rootView: TaskAppView(model: model, list: list, selectedTask: selectedTask))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(size)
        window.appearance = NSAppearance(named: .aqua)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        // The window's own background isn't part of the view, so the content area would come out
        // see-through (and dark on GitHub's dark theme). Flatten onto white, as the window shows it.
        try write(view: controller.view, to: url, background: .white)
    }

    private static func snapshot(_ view: some View, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try write(view: host, to: url)
    }

    private static func write(view: NSView, to url: URL, background: NSColor? = nil) throws {
        guard var rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let background, let image = rep.cgImage,
           let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: flat) {
            let bounds = CGRect(x: 0, y: 0, width: flat.pixelsWide, height: flat.pixelsHigh)
            context.cgContext.setFillColor(background.cgColor)
            context.cgContext.fill(bounds)
            context.cgContext.draw(image, in: bounds)
            flat.size = rep.size
            rep = flat
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
