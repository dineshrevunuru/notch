import Foundation
import Observation

/// A Pomodoro cycle: focus, a short break that starts by itself, repeat; after the last round,
/// a long break. The next focus round never starts by itself, so you begin each one on purpose.
/// Time is passed in rather than read, so every transition is testable.
@Observable
public final class PomodoroTimer {
    nonisolated public enum Phase: String, Codable, Sendable {
        case focus, shortBreak, longBreak

        public var isBreak: Bool { self != .focus }

        public var label: String {
            switch self {
            case .focus: "Focus"
            case .shortBreak: "Break"
            case .longBreak: "Long break"
            }
        }
    }

    nonisolated public struct Plan: Codable, Equatable, Identifiable, Sendable {
        public var name: String
        public var focusMinutes: Int
        public var shortBreakMinutes: Int
        public var longBreakMinutes: Int
        /// Focus rounds before the long break.
        public var rounds: Int

        public var id: String { name }

        public init(name: String, focusMinutes: Int, shortBreakMinutes: Int, longBreakMinutes: Int, rounds: Int) {
            self.name = name
            self.focusMinutes = focusMinutes
            self.shortBreakMinutes = shortBreakMinutes
            self.longBreakMinutes = longBreakMinutes
            self.rounds = max(1, rounds)
        }

        public static let classic = Plan(name: "Classic", focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, rounds: 4)
        public static let deep = Plan(name: "Deep work", focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30, rounds: 3)
        public static let sprint = Plan(name: "Sprint", focusMinutes: 15, shortBreakMinutes: 3, longBreakMinutes: 10, rounds: 4)
        public static let all = [classic, deep, sprint]

        public func minutes(_ phase: Phase) -> Int {
            switch phase {
            case .focus: focusMinutes
            case .shortBreak: shortBreakMinutes
            case .longBreak: longBreakMinutes
            }
        }

        /// "25 / 5, long 15 after 4"
        public var summary: String {
            "\(focusMinutes) / \(shortBreakMinutes), long \(longBreakMinutes) after \(rounds)"
        }
    }

    nonisolated public enum State: Equatable, Sendable {
        case idle
        case running(phase: Phase, round: Int, start: Date, end: Date)
        case paused(phase: Phase, round: Int, remaining: TimeInterval, total: TimeInterval)
        /// A break ended; this round's focus waits for you to start it.
        case ready(round: Int)
    }

    /// What just happened, so the app can drop a banner. Only for transitions that happen on time.
    nonisolated public enum Event: Equatable, Sendable {
        case focusEnded(round: Int, breakPhase: Phase, breakMinutes: Int)
        case breakEnded(nextRound: Int)
    }

    /// A phase that ended this long ago (the Mac was asleep) moves on quietly, with no banner or chime.
    public static let staleAfter: TimeInterval = 60

    public private(set) var state: State = .idle
    public var plan: Plan

    public init(plan: Plan = .classic) {
        self.plan = plan
    }

    // MARK: Reading

    public var phase: Phase? {
        switch state {
        case .running(let phase, _, _, _), .paused(let phase, _, _, _): phase
        case .idle, .ready: nil
        }
    }

    public var round: Int? {
        switch state {
        case .running(_, let round, _, _), .paused(_, let round, _, _), .ready(let round): round
        case .idle: nil
        }
    }

    /// Running or paused: a session is on screen.
    public var isActive: Bool { phase != nil }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public func remaining(at now: Date) -> TimeInterval? {
        switch state {
        case .running(_, _, _, let end): max(0, end.timeIntervalSince(now))
        case .paused(_, _, let remaining, _): remaining
        case .idle, .ready: nil
        }
    }

    /// 0 at the start of the phase, 1 at its end.
    public func progress(at now: Date) -> Double? {
        switch state {
        case .running(_, _, let start, let end):
            let total = end.timeIntervalSince(start)
            return total > 0 ? min(1, max(0, now.timeIntervalSince(start) / total)) : 1
        case .paused(_, _, let remaining, let total):
            return total > 0 ? min(1, max(0, 1 - remaining / total)) : 1
        case .idle, .ready:
            return nil
        }
    }

    // MARK: Controls

    /// Starts the waiting round's focus (round 1 from idle). `minutes` overrides the plan for this round only.
    public func startFocus(now: Date = .now, minutes: Int? = nil) {
        let round: Int
        if case .ready(let waiting) = state { round = waiting } else { round = 1 }
        let length = TimeInterval(max(1, minutes ?? plan.focusMinutes)) * 60
        state = .running(phase: .focus, round: round, start: now, end: now.addingTimeInterval(length))
    }

    public func pause(now: Date = .now) {
        guard case .running(let phase, let round, let start, let end) = state else { return }
        state = .paused(phase: phase, round: round, remaining: max(0, end.timeIntervalSince(now)), total: end.timeIntervalSince(start))
    }

    public func resume(now: Date = .now) {
        guard case .paused(let phase, let round, let remaining, let total) = state else { return }
        state = .running(phase: phase, round: round, start: now.addingTimeInterval(remaining - total), end: now.addingTimeInterval(remaining))
    }

    /// Ends the current phase now: a focus round goes straight to its break, a break to the next round.
    public func skip(now: Date = .now) {
        guard let phase, let round else { return }
        _ = finish(phase, round: round, at: now, stale: false)
    }

    /// Back to idle; the next start is round 1.
    public func stop() {
        state = .idle
    }

    /// Moves time forward. Returns an event when a phase ends on time.
    @discardableResult
    public func advance(to now: Date) -> Event? {
        guard case .running(let phase, let round, _, let end) = state, now >= end else { return nil }
        return finish(phase, round: round, at: now, stale: now.timeIntervalSince(end) > Self.staleAfter)
    }

    private func finish(_ phase: Phase, round: Int, at now: Date, stale: Bool) -> Event? {
        if phase == .focus {
            if stale {
                // Slept through the end: skip the break rather than starting one nobody asked for.
                state = .ready(round: round >= plan.rounds ? 1 : round + 1)
                return nil
            }
            let breakPhase: Phase = round >= plan.rounds ? .longBreak : .shortBreak
            let minutes = plan.minutes(breakPhase)
            state = .running(phase: breakPhase, round: round, start: now, end: now.addingTimeInterval(TimeInterval(minutes) * 60))
            return .focusEnded(round: round, breakPhase: breakPhase, breakMinutes: minutes)
        }
        let nextRound = phase == .longBreak ? 1 : round + 1
        state = .ready(round: nextRound)
        return stale ? nil : .breakEnded(nextRound: nextRound)
    }
}
