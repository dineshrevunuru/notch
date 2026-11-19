import Foundation

nonisolated public enum DistractionKind: String, Codable, CaseIterable, Sendable {
    case game, video, social, workSocial

    public var label: String {
        switch self {
        case .game: "Games"
        case .video: "Video"
        case .social: "Social feeds"
        case .workSocial: "X and LinkedIn"
        }
    }
}

/// What's pulling you away, by name: "YouTube", "Steam", "Reddit".
nonisolated public struct DistractionSource: Codable, Equatable, Hashable, Sendable {
    public let kind: DistractionKind
    public let name: String

    public init(kind: DistractionKind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// Opt-in: off until you turn it on.
nonisolated public struct DistractionSettings: Equatable, Sendable {
    public var enabled: Bool
    public var kinds: Set<DistractionKind>
    /// How long a distraction runs during the workday before a nudge.
    public var workdayThreshold: TimeInterval
    /// How long during a focus round.
    public var focusThreshold: TimeInterval
    /// A switch to something else shorter than this doesn't end the streak.
    public var grace: TimeInterval
    /// After a nudge you ignore, how long until the next one.
    public var repeatEvery: TimeInterval

    public init(
        enabled: Bool = false,
        kinds: Set<DistractionKind> = [.game, .video],
        workdayThreshold: TimeInterval = 15 * 60,
        focusThreshold: TimeInterval = 60,
        grace: TimeInterval = 60,
        repeatEvery: TimeInterval = 10 * 60
    ) {
        self.enabled = enabled
        self.kinds = kinds
        self.workdayThreshold = workdayThreshold
        self.focusThreshold = focusThreshold
        self.grace = grace
        self.repeatEvery = repeatEvery
    }
}

/// A nudge to drop as a banner.
nonisolated public struct Nudge: Equatable, Sendable {
    public let source: DistractionSource
    public let minutes: Int
    public let duringFocus: Bool

    public init(source: DistractionSource, minutes: Int, duringFocus: Bool) {
        self.source = source
        self.minutes = minutes
        self.duringFocus = duringFocus
    }
}

nonisolated public enum DistractionRules {
    static let videoSites: [String: String] = [
        "youtube.com": "YouTube", "youtu.be": "YouTube", "netflix.com": "Netflix", "primevideo.com": "Prime Video",
        "hotstar.com": "Hotstar", "aha.video": "aha", "twitch.tv": "Twitch", "hulu.com": "Hulu", "max.com": "Max",
        "disneyplus.com": "Disney+", "tv.apple.com": "Apple TV", "crunchyroll.com": "Crunchyroll",
    ]
    static let socialSites: [String: String] = [
        "reddit.com": "Reddit", "instagram.com": "Instagram", "facebook.com": "Facebook", "tiktok.com": "TikTok",
    ]
    static let workSocialSites: [String: String] = [
        "x.com": "X", "twitter.com": "X", "linkedin.com": "LinkedIn",
    ]
    static let videoApps: [String: String] = [
        "com.apple.TV": "TV", "org.videolan.vlc": "VLC", "com.colliderli.iina": "IINA", "com.amazon.aiv.AIVApp": "Prime Video",
    ]
    static let gameLaunchers: [String: String] = [
        "com.valvesoftware.steam": "Steam", "com.epicgames.EpicGamesLauncher": "Epic Games",
    ]

    /// Whether the front app or the site in the browser's active tab is a distraction you've turned on.
    /// `appCategory` is the app's `LSApplicationCategoryType`, which marks games.
    public static func classify(
        bundleID: String?, appName: String?, appCategory: String?, url: String?, kinds: Set<DistractionKind>
    ) -> DistractionSource? {
        if kinds.contains(.game) {
            if let category = appCategory, category.hasPrefix("public.app-category."), category.contains("games") {
                return DistractionSource(kind: .game, name: appName ?? "a game")
            }
            if let bundleID, let name = gameLaunchers[bundleID] {
                return DistractionSource(kind: .game, name: name)
            }
        }
        if kinds.contains(.video), let bundleID, let name = videoApps[bundleID] {
            return DistractionSource(kind: .video, name: name)
        }
        guard let url, let host = host(of: url) else { return nil }
        let lists: [(DistractionKind, [String: String])] = [(.video, videoSites), (.social, socialSites), (.workSocial, workSocialSites)]
        for (kind, sites) in lists where kinds.contains(kind) {
            if let name = match(host, in: sites) { return DistractionSource(kind: kind, name: name) }
        }
        return nil
    }

    /// "https://www.youtube.com/watch?v=…" → "youtube.com"; "m.reddit.com" → "m.reddit.com".
    public static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Exact domain or any subdomain of it ("music.youtube.com" counts as YouTube).
    private static func match(_ host: String, in sites: [String: String]) -> String? {
        for (domain, name) in sites where host == domain || host.hasSuffix("." + domain) {
            return name
        }
        return nil
    }
}

/// Follows what's in front over time and decides when a distraction has run long enough to nudge.
nonisolated public struct DistractionWatch: Sendable {
    /// When nudges apply: in a focus round, during the workday, or not at all (breaks, after hours, off).
    public enum Context: Equatable, Sendable { case focus, workday, off }

    public private(set) var current: DistractionSource?
    /// When this run of distraction started. Switching between distractions keeps it going.
    public private(set) var streakStart: Date?
    private var lastSeen: Date?
    private var lastNudge: Date?
    private var quietUntil: Date?

    public init() {}

    /// Feeds one look at the front app. Returns a nudge when one is due.
    public mutating func observe(_ source: DistractionSource?, at now: Date, context: Context, settings: DistractionSettings) -> Nudge? {
        if let source {
            if streakStart == nil { streakStart = now }
            current = source
            lastSeen = now
        } else if let seen = lastSeen, now.timeIntervalSince(seen) > settings.grace {
            // Back on something else for longer than a glance: the streak is over.
            current = nil
            streakStart = nil
            lastSeen = nil
            lastNudge = nil
        }

        guard settings.enabled, context != .off, let source, let start = streakStart else { return nil }
        if let quietUntil, now < quietUntil { return nil }
        let threshold = context == .focus ? settings.focusThreshold : settings.workdayThreshold
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= threshold else { return nil }
        if let last = lastNudge, now.timeIntervalSince(last) < settings.repeatEvery { return nil }
        lastNudge = now
        return Nudge(source: source, minutes: max(1, Int(elapsed / 60)), duringFocus: context == .focus)
    }

    /// "Snooze" or "It's work": no nudges until `date`.
    public mutating func quiet(until date: Date) {
        quietUntil = date
    }
}

/// Time spent on one distraction, for the evening wrap-up. Only the name is kept, never an address.
nonisolated public struct DistractionSpan: Codable, Equatable, Sendable {
    public let name: String
    public let kind: DistractionKind
    public let start: Date
    public let end: Date

    public var minutes: Double { max(0, end.timeIntervalSince(start)) / 60 }

    public init(name: String, kind: DistractionKind, start: Date, end: Date) {
        self.name = name
        self.kind = kind
        self.start = start
        self.end = end
    }
}
