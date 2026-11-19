import Foundation
import Testing
@testable import NotchCore

private var chicago: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// 2026-11-19 at hh:mm in Chicago.
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 19) -> Date {
    chicago.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func event(_ title: String, _ start: Date, _ end: Date) -> TimedEvent {
    TimedEvent(id: title, title: title, start: start, end: end)
}

/// ICU puts a narrow no-break space before AM/PM; compare against plain spaces.
private func plain(_ text: String?) -> String? {
    text?.replacingOccurrences(of: "\u{202F}", with: " ")
}

@Suite("Status line")
struct StatusEngineTests {
    @Test func insideAnEvent() {
        let review = event("Design review", at(14), at(14, 30))
        let status = StatusEngine.status(at: at(14, 6), events: [review], calendar: chicago)
        #expect(status.kind == .busy)
        #expect(status.headline == "In Design review")
        #expect(plain(status.detail) == "Until 2:30 PM · 24m left")
    }

    @Test func overlappingEventsWatchTheOneEndingFirst() {
        let long = event("Workshop", at(13), at(17))
        let short = event("Standup", at(14), at(14, 15))
        let status = StatusEngine.status(at: at(14, 5), events: [long, short], calendar: chicago)
        #expect(status.headline == "In Standup")
    }

    @Test func freeUntilTheNextEventToday() {
        let sync = event("Client sync", at(14, 30), at(15))
        let status = StatusEngine.status(at: at(12, 50), events: [sync], calendar: chicago)
        #expect(status.kind == .free)
        #expect(status.headline == "Free for 1h 40m")
        // The Upcoming list right below already names the next event.
        #expect(status.detail == nil)
    }

    @Test func eventStartingThisMinute() {
        let sync = event("Client sync", at(14, 30), at(15))
        let status = StatusEngine.status(at: at(14, 29).addingTimeInterval(30), events: [sync], calendar: chicago)
        #expect(status.kind == .busy)
        #expect(status.headline == "Client sync is starting")
    }

    @Test func nextEventIsTomorrow() {
        let standup = event("Standup", at(9, day: 20), at(9, 15, day: 20))
        let status = StatusEngine.status(at: at(18), events: [standup], calendar: chicago)
        #expect(status.kind == .clear)
        #expect(status.headline == "Clear for the rest of today")
        #expect(status.detail == nil)
    }

    @Test func nothingAhead() {
        let earlier = event("Morning call", at(9), at(9, 30))
        let status = StatusEngine.status(at: at(18), events: [earlier], calendar: chicago)
        #expect(status.headline == "Clear for the rest of today")
        #expect(status.detail == nil)
    }

    @Test func upcomingDropsEndedEventsAndTheHeadlineEvent() {
        let events = [
            event("Later", at(16), at(17)),
            event("Done", at(9), at(10)),
            event("Now", at(11), at(12)),
            event("Soon", at(13), at(14)),
        ]
        let titles = StatusEngine.upcoming(at: at(11, 30), events: events, limit: 4).map(\.title)
        #expect(titles == ["Soon", "Later"])
    }

    @Test func upcomingKeepsAnOverlappingEventTheStatusIsNotAbout() {
        let events = [event("Workshop", at(13), at(17)), event("Standup", at(14), at(14, 15))]
        let titles = StatusEngine.upcoming(at: at(14, 5), events: events, limit: 4).map(\.title)
        #expect(titles == ["Workshop"])
    }

    @Test func startingSoonOnlyWithinTenMinutes() {
        let sync = event("Client sync", at(14, 30), at(15))
        #expect(StatusEngine.startingSoon(at: at(14, 21), events: [sync])?.title == "Client sync")
        #expect(StatusEngine.startingSoon(at: at(14, 19), events: [sync]) == nil)
        #expect(StatusEngine.startingSoon(at: at(14, 31), events: [sync]) == nil)
    }

    @Test func timeLabels() {
        let now = at(11)
        #expect(StatusEngine.timeLabel(for: event("a", at(10, 30), at(12)), at: now, calendar: chicago) == "Now")
        #expect(plain(StatusEngine.timeLabel(for: event("b", at(14, 30), at(15)), at: now, calendar: chicago)) == "2:30 PM")
        #expect(plain(StatusEngine.timeLabel(for: event("c", at(9, day: 20), at(10, day: 20)), at: now, calendar: chicago)) == "Fri 9:00 AM")
    }
}

@Suite("Compact times")
struct CompactTimeTests {
    @Test func dropsZeroMinutes() {
        #expect(plain(TimeText.compactClock(at(17), calendar: chicago)) == "5 PM")
        #expect(plain(TimeText.compactClock(at(16, 15), calendar: chicago)) == "4:15 PM")
    }
}

@Suite("Durations")
struct DurationTextTests {
    @Test func short() {
        #expect(DurationText.short(45 * 60) == "45m")
        #expect(DurationText.short(2 * 3600) == "2h")
        #expect(DurationText.short(100 * 60) == "1h 40m")
        #expect(DurationText.short(20) == "1m")
        #expect(DurationText.short(0) == "1m")
    }

    @Test func countdown() {
        #expect(DurationText.countdown(25 * 60) == "25:00")
        #expect(DurationText.countdown(64.2) == "01:05")
        #expect(DurationText.countdown(3720) == "1:02:00")
        #expect(DurationText.countdown(-5) == "00:00")
    }
}
