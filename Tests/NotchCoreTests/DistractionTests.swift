import Foundation
import Testing
@testable import NotchCore

private let all: Set<DistractionKind> = Set(DistractionKind.allCases)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func m(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private let youtube = DistractionSource(kind: .video, name: "YouTube")
private let reddit = DistractionSource(kind: .social, name: "Reddit")

@Suite("Distraction rules")
struct DistractionRulesTests {
    @Test func gamesByCategoryAndLauncher() {
        let game = DistractionRules.classify(bundleID: "com.example.chess", appName: "Chess Pro",
                                             appCategory: "public.app-category.board-games", url: nil, kinds: all)
        #expect(game == DistractionSource(kind: .game, name: "Chess Pro"))
        #expect(DistractionRules.classify(bundleID: "com.valvesoftware.steam", appName: "Steam", appCategory: nil, url: nil, kinds: all)?.kind == .game)
        // Not counted when games are off.
        #expect(DistractionRules.classify(bundleID: "com.valvesoftware.steam", appName: "Steam", appCategory: nil, url: nil, kinds: [.video]) == nil)
    }

    @Test func videoAppsAndSites() {
        #expect(DistractionRules.classify(bundleID: "org.videolan.vlc", appName: "VLC", appCategory: nil, url: nil, kinds: all)?.name == "VLC")
        #expect(DistractionRules.classify(bundleID: "com.google.Chrome", appName: "Chrome", appCategory: nil,
                                          url: "https://www.youtube.com/watch?v=abc", kinds: all) == youtube)
        #expect(DistractionRules.classify(bundleID: "com.google.Chrome", appName: "Chrome", appCategory: nil,
                                          url: "https://music.youtube.com/", kinds: all) == youtube)
        #expect(DistractionRules.classify(bundleID: "com.google.Chrome", appName: "Chrome", appCategory: nil,
                                          url: "https://www.aha.video/", kinds: all)?.name == "aha")
    }

    @Test func socialAndWorkSocialAreSeparateChoices() {
        let linkedin = "https://www.linkedin.com/feed/"
        #expect(DistractionRules.classify(bundleID: nil, appName: nil, appCategory: nil, url: linkedin, kinds: all)?.kind == .workSocial)
        #expect(DistractionRules.classify(bundleID: nil, appName: nil, appCategory: nil, url: linkedin, kinds: [.social, .video]) == nil)
        #expect(DistractionRules.classify(bundleID: nil, appName: nil, appCategory: nil, url: "https://old.reddit.com/r/x", kinds: all) == reddit)
    }

    @Test func workSitesAndLookalikesDontCount() {
        for url in ["https://docs.google.com/", "https://github.com/", "https://notyoutube.com/", "https://figma.com/file/1"] {
            #expect(DistractionRules.classify(bundleID: "com.google.Chrome", appName: "Chrome", appCategory: nil, url: url, kinds: all) == nil)
        }
        #expect(DistractionRules.host(of: "not a url") == nil)
    }
}

@Suite("Distraction watch")
struct DistractionWatchTests {
    private let settings = DistractionSettings(enabled: true, kinds: all)

    @Test func nudgesAfterFifteenMinutesDuringTheWorkday() {
        var watch = DistractionWatch()
        #expect(watch.observe(youtube, at: m(0), context: .workday, settings: settings) == nil)
        #expect(watch.observe(youtube, at: m(14), context: .workday, settings: settings) == nil)
        #expect(watch.observe(youtube, at: m(15), context: .workday, settings: settings) == Nudge(source: youtube, minutes: 15, duringFocus: false))
        // Ignored: the next one waits ten minutes.
        #expect(watch.observe(youtube, at: m(20), context: .workday, settings: settings) == nil)
        #expect(watch.observe(youtube, at: m(25), context: .workday, settings: settings)?.minutes == 25)
    }

    @Test func nudgesAfterOneMinuteInAFocusRound() {
        var watch = DistractionWatch()
        _ = watch.observe(reddit, at: m(0), context: .focus, settings: settings)
        #expect(watch.observe(reddit, at: m(1), context: .focus, settings: settings)?.duringFocus == true)
    }

    @Test func aGlanceAwayKeepsTheStreak() {
        var watch = DistractionWatch()
        _ = watch.observe(youtube, at: m(0), context: .workday, settings: settings)
        _ = watch.observe(youtube, at: m(9.8), context: .workday, settings: settings)
        _ = watch.observe(nil, at: m(10.2), context: .workday, settings: settings)   // 24 s on something else
        // One streak, even across two sites.
        #expect(watch.observe(reddit, at: m(15), context: .workday, settings: settings)?.minutes == 15)
    }

    @Test func realWorkEndsTheStreak() {
        var watch = DistractionWatch()
        _ = watch.observe(youtube, at: m(0), context: .workday, settings: settings)
        _ = watch.observe(nil, at: m(5), context: .workday, settings: settings)      // five minutes on work
        #expect(watch.observe(youtube, at: m(15), context: .workday, settings: settings) == nil) // starts over
        #expect(watch.observe(youtube, at: m(30), context: .workday, settings: settings)?.minutes == 15)
    }

    @Test func quietTimeAndOffContextsNeverNudge() {
        var watch = DistractionWatch()
        _ = watch.observe(youtube, at: m(0), context: .workday, settings: settings)
        watch.quiet(until: m(60))
        #expect(watch.observe(youtube, at: m(30), context: .workday, settings: settings) == nil)
        #expect(watch.observe(youtube, at: m(61), context: .workday, settings: settings) != nil)

        var breakTime = DistractionWatch()
        _ = breakTime.observe(youtube, at: m(0), context: .off, settings: settings)
        #expect(breakTime.observe(youtube, at: m(40), context: .off, settings: settings) == nil)

        var disabled = DistractionWatch()
        let off = DistractionSettings(enabled: false, kinds: all)
        _ = disabled.observe(youtube, at: m(0), context: .workday, settings: off)
        #expect(disabled.observe(youtube, at: m(40), context: .workday, settings: off) == nil)
    }

    @Test func wrapUpTotalsPerName() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distraction-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TaskStore(fileURL: dir.appendingPathComponent("store.json"), legacyFileURL: nil)
        store.logDistraction(youtube, start: m(0), end: m(25))
        store.logDistraction(reddit, start: m(30), end: m(40))
        store.logDistraction(youtube, start: m(50), end: m(65))
        store.logDistraction(reddit, start: m(70), end: m(70.5)) // under a minute: dropped
        let totals = store.distractionMinutes(on: m(0))
        #expect(totals.map(\.name) == ["YouTube", "Reddit"])
        #expect(totals.map(\.minutes) == [40, 10])
    }
}
