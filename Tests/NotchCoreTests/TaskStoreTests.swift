import Foundation
import Testing
@testable import NotchCore

private func tempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func freshStore(_ dir: URL = tempDirectory()) -> TaskStore {
    TaskStore(fileURL: dir.appendingPathComponent("store.json"), legacyFileURL: dir.appendingPathComponent("tasks.json"))
}

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Chicago")!
    c.locale = Locale(identifier: "en_US")
    return c
}()

private func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Suite("Task store")
struct TaskStoreTests {
    @Test func addTrimsIgnoresBlankAndCapsLength() {
        let store = freshStore()
        #expect(store.add("   ") == nil)
        store.add("  Send the follow-up \n")
        store.add(String(repeating: "a", count: 900))
        #expect(store.tasks.map(\.title) == ["Send the follow-up", String(repeating: "a", count: TaskStore.maxTitleLength)])
    }

    @Test func subtaskTakesParentProject() {
        let store = freshStore()
        let client = store.addProject("Client")!
        let parent = store.add("Launch booking app", project: client.id)!
        let child = store.add("Write release notes", parent: parent.id)!
        #expect(child.projectID == client.id)
        #expect(store.children(of: parent.id).map(\.id) == [child.id])
    }

    @Test func movingAParentMovesItsSubtasks() {
        let store = freshStore()
        let job = store.addProject("Work")!
        let parent = store.add("Plan the launch")!
        let child = store.add("Write the brief", parent: parent.id)!
        var moved = store.task(parent.id)!
        moved.projectID = job.id
        store.update(moved)
        #expect(store.task(child.id)?.projectID == job.id)
    }

    @Test func completingAParentCompletesSubtasks() {
        let store = freshStore()
        let parent = store.add("Ship case study")!
        let a = store.add("Draft", parent: parent.id)!
        let b = store.add("Review", parent: parent.id)!
        store.toggle(a.id)
        #expect(store.subtaskProgress(of: parent.id)! == (1, 2))
        store.complete(parent.id)
        #expect(store.task(b.id)?.isDone == true)
        #expect(store.subtaskProgress(of: parent.id)! == (2, 2))
    }

    @Test func deleteRemovesSubtasksAndFreesDependents() {
        let store = freshStore()
        let parent = store.add("Research")!
        let child = store.add("Collect sources", parent: parent.id)!
        let waiting = store.add("Write summary")!
        #expect(store.addDependency(waiting.id, blockedBy: child.id))
        #expect(store.isBlocked(waiting.id))
        store.delete(parent.id)
        #expect(store.task(child.id) == nil)
        #expect(store.task(waiting.id)?.blockedBy == [])
        #expect(!store.isBlocked(waiting.id))
    }

    @Test func dependenciesBlockUntilDoneAndRefuseLoops() {
        let store = freshStore()
        let a = store.add("Design")!
        let b = store.add("Build")!
        let c = store.add("Launch")!
        #expect(store.addDependency(b.id, blockedBy: a.id))
        #expect(store.addDependency(c.id, blockedBy: b.id))
        #expect(store.addDependency(a.id, blockedBy: c.id) == false) // a → c → b → a
        #expect(store.addDependency(a.id, blockedBy: a.id) == false)
        #expect(store.isBlocked(c.id))
        #expect(!store.dependencyCandidates(for: a.id).contains { $0.id == c.id })

        store.complete(a.id)
        #expect(!store.isBlocked(b.id))
        #expect(store.isBlocked(c.id))
    }

    @Test func repeatingTaskSchedulesNextWithReminderAndFreshSubtasks() {
        let store = freshStore()
        var task = store.add("Weekly review")!
        task.due = DueDate(date: at(19, 17), hasTime: true)
        task.reminder = at(19, 16, 45)
        task.recurrence = Recurrence(unit: .week)
        store.update(task)
        let step = store.add("Clear inbox", parent: task.id)!
        store.complete(step.id, now: at(19, 16))

        store.complete(task.id, now: at(19, 17, 30), calendar: calendar)

        let next = store.tasks.first { $0.title == "Weekly review" && !$0.isDone }
        #expect(next?.due == DueDate(date: at(26, 17), hasTime: true))
        #expect(next?.reminder == at(26, 16, 45))
        #expect(next?.reminderHandled == false)
        #expect(store.children(of: next!.id).map(\.isDone) == [false])
    }

    @Test func dismissedReminderStillRepeats() {
        let store = freshStore()
        var task = store.add("Stand-up notes")!
        task.due = DueDate(date: at(19, 9), hasTime: true)
        task.reminder = at(19, 8, 55)
        task.recurrence = Recurrence(unit: .day)
        store.update(task)
        store.dismissReminder(task.id)
        #expect(!TaskRules.isRinging(store.task(task.id)!, now: at(19, 9)))

        store.complete(task.id, now: at(19, 9, 30), calendar: calendar)
        let next = store.tasks.first { !$0.isDone }
        #expect(next?.reminder == at(20, 8, 55))
    }

    @Test func snoozeRingsLaterAndEditingTheReminderResetsIt() {
        let store = freshStore()
        var task = store.add("Call the dentist")!
        task.reminder = at(19, 10)
        store.update(task)
        #expect(TaskRules.isRinging(store.task(task.id)!, now: at(19, 10, 1)))

        store.snoozeReminder(task.id, minutes: 10, now: at(19, 10, 1))
        #expect(!TaskRules.isRinging(store.task(task.id)!, now: at(19, 10, 5)))
        #expect(TaskRules.isRinging(store.task(task.id)!, now: at(19, 10, 11)))

        var edited = store.task(task.id)!
        edited.reminder = at(19, 15)
        store.update(edited)
        #expect(store.task(task.id)?.snoozedUntil == nil)
    }

    @Test func boardMovesBetweenColumns() {
        let store = freshStore()
        let card = store.add("Hero section")!
        #expect(store.task(card.id)?.column == .todo)

        store.move(card.id, to: .doing, now: at(19, 13))
        #expect(store.task(card.id)?.column == .doing)
        #expect(store.task(card.id)?.startedAt == at(19, 13))

        store.move(card.id, to: .done, now: at(19, 15))
        #expect(store.task(card.id)?.isDone == true)

        store.move(card.id, to: .todo)
        #expect(store.task(card.id)?.column == .todo) // leaving Done reopens it
        #expect(store.task(card.id)?.isDone == false)
    }

    @Test func droppingOnACardPlacesItAbove() {
        let store = freshStore()
        let a = store.add("A")!, b = store.add("B")!, c = store.add("C")!
        let column = { TaskRules.board(store.tasks, project: nil, now: at(19), calendar: calendar)[.todo]! }
        store.move(c.id, to: .todo, before: a.id, in: column())
        #expect(column().map(\.title) == ["C", "A", "B"])
        store.move(a.id, to: .todo, before: nil, in: column())
        #expect(column().map(\.title) == ["C", "B", "A"])
        _ = b
    }

    @Test func boardShowsTopLevelCardsAndTheLastWeekOfDone() {
        let store = freshStore()
        let parent = store.add("Parent", now: at(10))!
        store.add("Child", parent: parent.id, now: at(10))
        let old = store.add("Old win", now: at(1))!
        store.complete(old.id, now: at(5))
        let recent = store.add("Recent win", now: at(18))!
        store.complete(recent.id, now: at(18))

        let board = TaskRules.board(store.tasks, project: nil, now: at(19), calendar: calendar)
        #expect(board[.todo]!.map(\.title) == ["Parent"])
        #expect(board[.done]!.map(\.title) == ["Recent win"])
    }

    @Test func reopeningClearsDoing() {
        let store = freshStore()
        let card = store.add("x")!
        store.move(card.id, to: .doing)
        store.complete(card.id)
        store.reopen(card.id)
        #expect(store.task(card.id)?.status == .todo)
    }

    @Test func deletingAProjectKeepsItsTasks() {
        let store = freshStore()
        let p = store.addProject("Side project")!
        let t = store.add("Tariff model", project: p.id)!
        #expect(store.addProject("side project")?.id == p.id) // no duplicates by case
        store.deleteProject(p.id)
        #expect(store.task(t.id)?.projectID == nil)
    }

    @Test func tagsAreNormalized() {
        #expect(Tags.parse("client, #Deep work,  ,client , urgent") == ["client", "Deep work", "urgent"])
    }

    @Test func persistsAcrossLaunches() {
        let dir = tempDirectory()
        let first = freshStore(dir)
        let project = first.addProject("Client")!
        let task = first.add("Survives a relaunch", project: project.id)!
        first.complete(task.id)
        first.saveNow()

        let second = freshStore(dir)
        #expect(second.projects.map(\.name) == ["Client"])
        #expect(second.task(task.id)?.isDone == true)
    }

    @Test func migratesTheFirstVersionsList() throws {
        let dir = tempDirectory()
        let legacy = """
        [{"id":"7B0C1E7A-2F7B-4B7E-9C1A-2B9E3C2D1A01","title":"Old task","createdAt":"2026-11-19T15:00:00Z"},
         {"id":"7B0C1E7A-2F7B-4B7E-9C1A-2B9E3C2D1A02","title":"Old done","createdAt":"2026-11-19T15:00:00Z","completedAt":"2026-11-19T16:00:00Z"}]
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("tasks.json"))

        let store = freshStore(dir)
        #expect(store.tasks.map(\.title) == ["Old task", "Old done"])
        #expect(store.tasks[1].isDone)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains("store.json"))
        #expect(files.contains("tasks.v1-migrated.json"))
        #expect(!files.contains("tasks.json"))
    }

    @Test func unreadableFileIsKeptNotOverwritten() throws {
        let dir = tempDirectory()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("store.json"))
        let store = freshStore(dir)
        #expect(store.tasks.isEmpty)
        #expect(store.lastError != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.contains("unreadable") })
    }

    @Test func picksUpOutsideEdits() throws {
        let dir = tempDirectory()
        let store = freshStore(dir)
        store.add("Mine")
        store.saveNow()

        // Something else (a script, a text editor) rewrites the file.
        let url = dir.appendingPathComponent("store.json")
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"Mine\"", with: "\"Edited elsewhere\"")
        try json.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        store.reloadIfChangedOnDisk()
        #expect(store.tasks.map(\.title) == ["Edited elsewhere"])
    }

    @Test func leanEntriesDecode() throws {
        let json = #"{"id":"7B0C1E7A-2F7B-4B7E-9C1A-2B9E3C2D1A09","title":"Added by a script","createdAt":"2026-11-19T15:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.priority == .none && task.tags.isEmpty && task.blockedBy.isEmpty && !task.reminderHandled)
    }
}

@Suite("Task rules")
struct TaskRulesTests {
    private func task(_ title: String, due: DueDate? = nil, reminder: Date? = nil, priority: Priority = .none) -> TaskItem {
        TaskItem(title: title, priority: priority, due: due, reminder: reminder, createdAt: at(1))
    }

    @Test func overdueAndToday() {
        let now = at(19, 14)
        #expect(TaskRules.isOverdue(task("timed earlier", due: DueDate(date: at(19, 13), hasTime: true)), now: now, calendar: calendar))
        #expect(!TaskRules.isOverdue(task("today, no time", due: .day(at(19), calendar: calendar)), now: now, calendar: calendar))
        #expect(TaskRules.isDueToday(task("today, no time", due: .day(at(19), calendar: calendar)), now: now, calendar: calendar))
        #expect(TaskRules.isOverdue(task("yesterday", due: .day(at(18), calendar: calendar)), now: now, calendar: calendar))
    }

    @Test func todayOrder() {
        let now = at(19, 14)
        let tasks = [
            task("today low", due: .day(at(19), calendar: calendar), priority: .low),
            task("today 4pm", due: DueDate(date: at(19, 16), hasTime: true)),
            task("overdue", due: .day(at(17), calendar: calendar)),
            task("ringing", reminder: at(19, 13)),
            task("today high", due: .day(at(19), calendar: calendar), priority: .high),
            task("next week", due: .day(at(26), calendar: calendar)),
        ]
        let titles = TaskRules.today(tasks, now: now, calendar: calendar).map(\.title)
        #expect(titles == ["ringing", "overdue", "today 4pm", "today high", "today low"])

        let glance = TaskRules.glance(tasks, now: now, calendar: calendar)
        #expect(glance == TaskGlance(ringing: 1, overdue: 1, dueToday: 3))
    }

    @Test func upNextIsTheSoonerOfMeetingAndTask() {
        // A typical afternoon: a 4 PM meeting, a task due at 5 PM, another due today, one in Doing.
        let now = at(19, 14, 17)
        var hero = task("Landing page hero", due: DueDate(date: at(19, 17), hasTime: true))
        hero.sortOrder = 1
        let figma = task("Prepare the deck", due: .day(at(19), calendar: calendar))
        var doing = task("Polish the app")
        doing.status = .doing
        let meeting = TimedEvent(id: "m", title: "Team meeting", start: at(19, 16), end: at(19, 16, 30))

        #expect(TaskRules.upNext([hero, figma, doing], events: [meeting], now: now, calendar: calendar) == .meeting(meeting))
        // After the meeting starts, the 5 PM task is next.
        #expect(TaskRules.upNext([hero, figma, doing], events: [meeting], now: at(19, 16, 5), calendar: calendar) == .task(hero, urgency: .normal))
        // With no timed work left, the day-only task.
        #expect(TaskRules.upNext([figma, doing], events: [], now: now, calendar: calendar) == .task(figma, urgency: .normal))
    }

    @Test func upNextPutsRingingFirstAndLateBeforeDayOnly() {
        let now = at(19, 14)
        let ringing = task("Call back", reminder: at(19, 13, 50))
        let late = task("Late", due: .day(at(17), calendar: calendar))
        let dayOnly = task("Day only", due: .day(at(19), calendar: calendar))
        let meeting = TimedEvent(id: "m", title: "Sync", start: at(19, 15), end: at(19, 15, 30))
        #expect(TaskRules.upNext([dayOnly, late, ringing], events: [meeting], now: now, calendar: calendar) == .task(ringing, urgency: .ringing))
        #expect(TaskRules.upNext([dayOnly, late], events: [], now: now, calendar: calendar) == .task(late, urgency: .late))
    }

    @Test func agendaMergesMeetingsAndTasksByTime() {
        let now = at(19, 14)
        var doing = task("Polish the app")
        doing.status = .doing
        var otherDoing = task("Second card")
        otherDoing.status = .doing
        let ringing = task("Hero section", due: DueDate(date: at(19, 17), hasTime: true), reminder: at(19, 13, 30))
        let late = task("Late", due: .day(at(17), calendar: calendar))
        let at3 = task("Send invoice", due: DueDate(date: at(19, 15), hasTime: true))
        let untimed = task("Prepare the deck", due: .day(at(19), calendar: calendar))
        let inNow = TimedEvent(id: "now", title: "Running meeting", start: at(19, 13, 30), end: at(19, 14, 30))
        let at4 = TimedEvent(id: "m", title: "Team meeting", start: at(19, 16), end: at(19, 16, 30))
        let tomorrow = TimedEvent(id: "t", title: "Standup", start: at(20, 9), end: at(20, 9, 15))

        let items = TaskRules.agenda(
            [untimed, at3, late, ringing, otherDoing, doing], events: [tomorrow, at4, inNow],
            now: now, calendar: calendar, excluding: doing.id
        )
        let titles = items.map { item -> String in
            switch item {
            case .task(let t): t.title
            case .event(let e): e.title
            }
        }
        #expect(titles == ["Second card", "Hero section", "Late", "Send invoice", "Team meeting", "Prepare the deck", "Standup"])
    }

    @Test func upcomingGroupsByDay() {
        let now = at(19, 14)
        let tasks = [
            task("b", due: DueDate(date: at(21, 9), hasTime: true)),
            task("a", due: .day(at(20), calendar: calendar)),
            task("c", due: .day(at(21), calendar: calendar)),
            task("today", due: .day(at(19), calendar: calendar)),
        ]
        let groups = TaskRules.upcoming(tasks, now: now, calendar: calendar)
        #expect(groups.map { $0.tasks.map(\.title) } == [["a"], ["c", "b"]])
    }

    @Test func recurrenceSkipsPastOccurrences() {
        let daily = Recurrence(unit: .day)
        let due = DueDate.day(at(10), calendar: calendar)
        #expect(TaskRules.nextDue(after: due, rule: daily, now: at(19, 9), calendar: calendar) == .day(at(19), calendar: calendar))
        let monthly = Recurrence(unit: .month, interval: 1)
        let end = DueDate.day(at(30), calendar: calendar)
        #expect(TaskRules.nextDue(after: end, rule: monthly, now: at(30, 9), calendar: calendar).date
            == calendar.date(from: DateComponents(year: 2026, month: 12, day: 30)))
        #expect(Recurrence(unit: .week, interval: 2).label == "Every 2 weeks")
    }

    @Test func labels() {
        let now = at(19, 14)
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(TaskRules.dueLabel(.day(at(19), calendar: calendar), now: now, calendar: calendar) == "Today")
        #expect(plain(TaskRules.dueLabel(DueDate(date: at(19, 16), hasTime: true), now: now, calendar: calendar)) == "4:00 PM")
        #expect(TaskRules.dueLabel(.day(at(20), calendar: calendar), now: now, calendar: calendar) == "Tomorrow")
        #expect(TaskRules.dueLabel(.day(at(23), calendar: calendar), now: now, calendar: calendar) == "Mon")
        #expect(TaskRules.dueLabel(.day(at(30), calendar: calendar), now: now, calendar: calendar) == "Nov 30")
        #expect(TaskRules.lateness(.day(at(17), calendar: calendar), now: now, calendar: calendar) == "2d late")
        #expect(TaskRules.lateness(DueDate(date: at(19, 13, 40), hasTime: true), now: now, calendar: calendar) == "20m late")
    }
}

@Suite("Alerts")
struct AlertPlannerTests {
    @Test func reminderDropsOnceThenStays() {
        let t = TaskItem(title: "Call the dentist", reminder: at(19, 10), createdAt: at(1))
        let first = AlertPlanner.plan(now: at(19, 10, 1), tasks: [t], events: [], seen: [])
        #expect(first.alerts == [.reminder(taskID: t.id, title: "Call the dentist", at: at(19, 10))])
        let again = AlertPlanner.plan(now: at(19, 10, 2), tasks: [t], events: [], seen: first.consumed)
        #expect(again.alerts.isEmpty)
    }

    @Test func manyRemindersFoldIntoOne() {
        let tasks = (1...4).map { TaskItem(title: "R\($0)", reminder: at(19, 8, $0), createdAt: at(1)) }
        let plan = AlertPlanner.plan(now: at(19, 12), tasks: tasks, events: [], seen: [])
        #expect(plan.alerts == [.reminders(count: 4)])
        #expect(plan.consumed.count == 5)
        #expect(AlertPlanner.plan(now: at(19, 12, 1), tasks: tasks, events: [], seen: plan.consumed).alerts.isEmpty)
    }

    @Test func deadlineOnlyAsItArrives() {
        let t = TaskItem(title: "Submit form", due: DueDate(date: at(19, 15), hasTime: true), createdAt: at(1))
        #expect(AlertPlanner.plan(now: at(19, 14, 59), tasks: [t], events: [], seen: []).alerts.isEmpty)
        #expect(AlertPlanner.plan(now: at(19, 15, 1), tasks: [t], events: [], seen: []).alerts.count == 1)
        #expect(AlertPlanner.plan(now: at(19, 18), tasks: [t], events: [], seen: []).alerts.isEmpty)
    }

    @Test func eventFiveMinutesOut() {
        let e = TimedEvent(id: "e", title: "Weekly sync", start: at(19, 14, 30), end: at(19, 15))
        #expect(AlertPlanner.plan(now: at(19, 14, 24), tasks: [], events: [e], seen: []).alerts.isEmpty)
        #expect(AlertPlanner.plan(now: at(19, 14, 26), tasks: [], events: [e], seen: []).alerts
            == [.eventSoon(eventID: "e", title: "Weekly sync", start: at(19, 14, 30))])
    }

    @Test func focusHoldsTaskBannersButNotMeetings() {
        let id = UUID()
        #expect(AlertPlanner.isHeldDuringFocus(.reminder(taskID: id, title: "x", at: at(19))))
        #expect(AlertPlanner.isHeldDuringFocus(.due(taskID: id, title: "x", at: at(19))))
        #expect(AlertPlanner.isHeldDuringFocus(.reminders(count: 3)))
        #expect(!AlertPlanner.isHeldDuringFocus(.eventSoon(eventID: "e", title: "Sync", start: at(19))))
        #expect(!AlertPlanner.isHeldDuringFocus(.breakEnded(nextRound: 2, rounds: 4, at: at(19))))
    }

    @Test func doneOrDismissedTasksDontRing() {
        var t = TaskItem(title: "x", reminder: at(19, 10), createdAt: at(1))
        t.reminderHandled = true
        #expect(AlertPlanner.plan(now: at(19, 11), tasks: [t], events: [], seen: []).alerts.isEmpty)
        t.reminderHandled = false
        t.completedAt = at(19, 9)
        #expect(AlertPlanner.plan(now: at(19, 11), tasks: [t], events: [], seen: []).alerts.isEmpty)
    }
}

@Suite("Pomodoro")
struct PomodoroTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func m(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    @Test func fullClassicCycle() {
        let timer = PomodoroTimer(plan: .classic)
        var clock = 0.0
        for round in 1...4 {
            timer.startFocus(now: m(clock))
            #expect(timer.phase == .focus && timer.round == round)
            #expect(timer.advance(to: m(clock + 24)) == nil)

            clock += 25
            let isLast = round == 4
            #expect(timer.advance(to: m(clock)) == .focusEnded(round: round, breakPhase: isLast ? .longBreak : .shortBreak, breakMinutes: isLast ? 15 : 5))
            #expect(timer.phase == (isLast ? .longBreak : .shortBreak)) // the break starts by itself

            clock += isLast ? 15 : 5
            #expect(timer.advance(to: m(clock)) == .breakEnded(nextRound: isLast ? 1 : round + 1))
            #expect(timer.state == .ready(round: isLast ? 1 : round + 1)) // the next focus waits for you
            #expect(!timer.isActive)
        }
    }

    @Test func pauseKeepsTheRemainingTime() {
        let timer = PomodoroTimer(plan: .classic)
        timer.startFocus(now: m(0))
        timer.pause(now: m(10))
        #expect(timer.remaining(at: m(500)) == TimeInterval(15 * 60))
        #expect(timer.progress(at: m(500)) == 0.4)
        #expect(timer.advance(to: m(500)) == nil)

        timer.resume(now: m(60))
        #expect(timer.remaining(at: m(61)) == TimeInterval(14 * 60))
        #expect(timer.progress(at: m(60)) == 0.4)
        #expect(timer.advance(to: m(75)) != nil)
    }

    @Test func skipMovesToTheNextPhase() {
        let timer = PomodoroTimer(plan: .classic)
        timer.startFocus(now: m(0))
        timer.skip(now: m(3))
        #expect(timer.phase == .shortBreak)
        #expect(timer.remaining(at: m(3)) == TimeInterval(5 * 60))
        timer.skip(now: m(4))
        #expect(timer.state == .ready(round: 2))
    }

    @Test func sleepingThroughTheEndMovesOnQuietly() {
        let timer = PomodoroTimer(plan: .classic)
        timer.startFocus(now: m(0))
        #expect(timer.advance(to: m(180)) == nil) // no banner, no chime, no surprise break
        #expect(timer.state == .ready(round: 2))
    }

    @Test func customLengthAndStop() {
        let timer = PomodoroTimer(plan: .sprint)
        timer.startFocus(now: m(0), minutes: 50)
        #expect(timer.remaining(at: m(0)) == TimeInterval(50 * 60))
        timer.stop()
        #expect(timer.state == .idle)
        timer.startFocus(now: m(1))
        #expect(timer.round == 1)
        #expect(timer.remaining(at: m(1)) == TimeInterval(15 * 60))
    }

    @Test func plans() {
        #expect(PomodoroTimer.Plan.classic.summary == "25 / 5, long 15 after 4")
        #expect(PomodoroTimer.Plan.all.map(\.name) == ["Classic", "Deep work", "Sprint"])
    }
}
