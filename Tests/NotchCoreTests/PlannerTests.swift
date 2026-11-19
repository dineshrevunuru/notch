import Foundation
import Testing
@testable import NotchCore

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Chicago")!
    c.locale = Locale(identifier: "en_US")
    return c
}()

/// November 2026: the 19th is a Thursday, the 21st a Saturday.
private func at(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func store() -> TaskStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("planner-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return TaskStore(fileURL: dir.appendingPathComponent("store.json"), legacyFileURL: nil)
}

@Suite("Planner")
struct PlannerTests {
    private let workday = Workday(startHour: 9, endHour: 18)

    @Test func freeTimeCountsOverlappingMeetingsOnce() {
        let events = [
            TimedEvent(id: "a", title: "Sync", start: at(19, 10), end: at(19, 11)),
            TimedEvent(id: "b", title: "Review", start: at(19, 10, 30), end: at(19, 12)),
            TimedEvent(id: "c", title: "Evening", start: at(19, 19), end: at(19, 20)), // after hours
        ]
        let morning = Planner.time(on: at(19, 8), workday: workday, events: events, calendar: calendar)
        #expect(morning.meetings == 120)
        #expect(morning.free == 9 * 60 - 120)

        let afternoon = Planner.time(on: at(19, 13), workday: workday, events: events, calendar: calendar)
        #expect(afternoon == (free: 300, meetings: 0))

        let evening = Planner.time(on: at(19, 19), workday: workday, events: events, calendar: calendar)
        #expect(evening == (free: 0, meetings: 0))
    }

    @Test func capacityKeepsATwentyPercentBuffer() {
        #expect(Capacity.of(planned: 300, free: 420) == .fits)   // 71%
        #expect(Capacity.of(planned: 360, free: 420) == .tight)  // 86%
        #expect(Capacity.of(planned: 450, free: 420) == .over)
        #expect(Capacity.of(planned: 0, free: 0) == .fits)
        #expect(Capacity.of(planned: 30, free: 0) == .over)
    }

    @Test func carryOverIsOverdueAndYesterdaysDoing() {
        let s = store()
        var late = s.add("Late", now: at(15))!
        late.due = .day(at(18), calendar: calendar)
        s.update(late)
        let stale = s.add("Stale doing", now: at(15))!
        s.move(stale.id, to: .doing, now: at(18, 15))
        let fresh = s.add("Started today", now: at(19, 8))!
        s.move(fresh.id, to: .doing, now: at(19, 9))

        let titles = Planner.carryOver(s.tasks, now: at(19, 9, 30), calendar: calendar).map(\.title)
        #expect(Set(titles) == ["Late", "Stale doing"])
    }

    @Test func candidatesPutTodayFirstAndSkipBlocked() {
        let s = store()
        let someday = s.add("Someday", now: at(10))!
        var today = s.add("Due today", now: at(12))!
        today.due = .day(at(19), calendar: calendar)
        s.update(today)
        var urgent = s.add("High priority", now: at(11))!
        urgent.priority = .high
        s.update(urgent)
        let waiting = s.add("Waiting", now: at(9))!
        s.addDependency(waiting.id, blockedBy: someday.id)

        let titles = Planner.candidates(s.tasks, now: at(19, 9), calendar: calendar).map(\.title)
        #expect(titles.first == "Due today")
        #expect(titles.contains("High priority"))
        #expect(!titles.contains("Waiting"))
    }

    @Test func savingAPlanFillsDoingWithExactlyThePicks() {
        let s = store()
        let a = s.add("A")!, b = s.add("B")!, c = s.add("C")!, d = s.add("D")!
        s.move(d.id, to: .doing) // left over from yesterday, not picked
        s.savePlan(day: "2026-11-19", picks: [a.id, b.id, c.id, d.id], now: at(19, 9))

        let plan = s.plan(for: "2026-11-19")!
        #expect(plan.taskIDs == [a.id, b.id, c.id]) // capped at three
        #expect(s.tasks.filter { $0.status == .doing }.map(\.title).sorted() == ["A", "B", "C"])
        #expect(s.task(d.id)?.status == .todo)
    }

    @Test func closingADayKeepsTheNoteForTomorrow() {
        let s = store()
        s.savePlan(day: "2026-11-19", picks: [], now: at(19, 9))
        s.closeDay("2026-11-19", note: "  Start with the hero copy  ", now: at(19, 18))
        #expect(s.plan(for: "2026-11-19")?.isClosed == true)
        #expect(s.previousPlan(before: "2026-11-20")?.note == "Start with the hero copy")
    }

    @Test func rescheduleKeepsTheTimeOfDay() {
        let s = store()
        var t = s.add("Call")!
        t.due = DueDate(date: at(18, 15, 30), hasTime: true)
        s.update(t)
        s.reschedule(t.id, to: at(20), calendar: calendar)
        #expect(s.task(t.id)?.due == DueDate(date: at(20, 15, 30), hasTime: true))
        s.unschedule(t.id)
        #expect(s.task(t.id)?.due == nil)
    }

    @Test func focusTimeAddsUpPerDayAndPerTask() {
        let s = store()
        let t = s.add("Hero")!
        s.logFocus(start: at(19, 9), end: at(19, 9, 25), task: t.id)
        s.logFocus(start: at(19, 10), end: at(19, 10, 12), task: nil)
        s.logFocus(start: at(19, 11), end: at(19, 11, 0).addingTimeInterval(30), task: t.id) // under a minute: dropped
        s.logFocus(start: at(18, 9), end: at(18, 9, 25), task: t.id)
        #expect(s.focusMinutes(on: at(19), calendar: calendar) == 37)
        #expect(s.focusMinutes(for: t.id) == 50)
    }

    @Test func plannedMinutesUseADefaultForUnestimatedPicks() {
        let picks = [
            TaskItem(title: "a", estimateMinutes: 60, createdAt: at(1)),
            TaskItem(title: "b", createdAt: at(1)),
        ]
        #expect(Planner.plannedMinutes(picks) == 60 + Planner.defaultEstimate)
    }

    @Test func promptsAtTheStartAndEndOfWeekdays() {
        #expect(Planner.prompt(now: at(19, 8), workday: workday, plan: nil, calendar: calendar) == nil)
        #expect(Planner.prompt(now: at(19, 9, 5), workday: workday, plan: nil, calendar: calendar) == .planDay(day: "2026-11-19"))
        #expect(Planner.prompt(now: at(19, 17, 30), workday: workday, plan: nil, calendar: calendar) == nil) // too late to plan

        let plan = DayPlan(day: "2026-11-19", taskIDs: [], plannedAt: at(19, 9))
        #expect(Planner.prompt(now: at(19, 12), workday: workday, plan: plan, calendar: calendar) == nil)
        #expect(Planner.prompt(now: at(19, 18, 2), workday: workday, plan: plan, calendar: calendar) == .wrapUpDay(day: "2026-11-19"))

        var closed = plan
        closed.closedAt = at(19, 17)
        #expect(Planner.prompt(now: at(19, 18, 2), workday: workday, plan: closed, calendar: calendar) == nil)
        #expect(Planner.prompt(now: at(21, 10), workday: workday, plan: nil, calendar: calendar) == nil) // Saturday
    }

    @Test func plansSurviveARelaunch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("planner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("store.json")
        let first = TaskStore(fileURL: url, legacyFileURL: nil)
        let t = first.add("Hero")!
        first.savePlan(day: "2026-11-19", picks: [t.id], now: at(19, 9))
        first.logFocus(start: at(19, 9), end: at(19, 9, 25), task: t.id)
        first.saveNow()

        let second = TaskStore(fileURL: url, legacyFileURL: nil)
        #expect(second.plan(for: "2026-11-19")?.taskIDs == [t.id])
        #expect(second.focusMinutes(for: t.id) == 25)
    }

    @Test func dayKeysAndWorkdayLabel() {
        #expect(Planner.dayKey(at(19, 23, 59), calendar: calendar) == "2026-11-19")
        #expect(Workday(startHour: 9, endHour: 18).label == "9 AM – 6 PM")
    }
}
