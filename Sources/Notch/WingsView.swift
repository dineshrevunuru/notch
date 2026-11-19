import NotchCore
import SwiftUI

/// The glance beside the closed notch.
/// Left: up next, in the default text color. Right: what's happening now, in the active color —
/// blue normally, orange in focus mode. During focus a thin orange line also fills along
/// the bottom edge, so the session's progress is visible from anywhere on the screen.
///
/// Each wing keeps its full width even when it has nothing to show. If an empty wing collapsed,
/// the other would slide toward the middle and its text would end up under the camera.
struct WingsView: View {
    let model: NotchModel
    let metrics: NotchMetrics
    /// The open notch keeps the same compact wings in the band beside the camera, exactly where
    /// they were, so what you glanced at is still there; the panel below spells the names out.
    /// Only the focus line gives way, to the panel's own progress bar.
    var isOpen = false

    var body: some View {
        // Compact (an icon and a short value), the way the Dynamic Island's compact view is, so
        // the wings cover as little of the menu bar as possible.
        let width = NotchMetrics.compactWingWidth
        HStack(spacing: 0) {
            Color.clear
                .frame(width: width)
                .overlay { if let signal = model.leftSignal { LeftWing(signal: signal, compact: true) } }

            Color.clear.frame(width: metrics.notchSize.width)

            Color.clear
                .frame(width: width)
                .overlay { if let signal = model.rightSignal { RightWing(signal: signal, compact: true) } }
        }
        .frame(height: metrics.notchSize.height)
        .lineLimit(1)
        .overlay(alignment: .bottom) {
            if model.isFocusing && !isOpen {
                FocusLine(
                    progress: model.pomodoro.progress(at: model.now) ?? 0,
                    paused: model.pomodoro.isPaused
                )
                .padding(.horizontal, NotchMetrics.radii(.closed(wings: true)).bottom + 4)
                .padding(.bottom, 1.5)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Up next: default text color, with one small mark for urgency.
private struct LeftWing: View {
    let signal: LeftSignal
    var compact = false

    var body: some View {
        Group {
            switch signal {
            case .nextTask(let title, let time, let urgency):
                HStack(spacing: 6) {
                    switch urgency {
                    case .ringing:
                        Image(systemName: "bell.fill").foregroundStyle(Ink.accent)
                    case .late:
                        Image(systemName: "circle").foregroundStyle(Ink.late)
                    case .normal:
                        Image(systemName: "circle").foregroundStyle(Ink.secondary)
                    }
                    if !compact {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .truncationMode(.tail)
                    }
                    if let time {
                        Text(time)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Ink.secondary)
                            .fixedSize()
                    }
                }
                .imageScale(.small)
                .font(.system(size: 11, weight: .bold))
                .accessibilityLabel(label(title: title, time: time, urgency: urgency))
            case .nextMeeting(let title, let time, let minutes):
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                    if !compact {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .truncationMode(.tail)
                    }
                    // Close to the start, how long until is what matters; further out, the time.
                    Text(minutes <= 15 ? "in \(minutes)m" : time)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(minutes <= 15 ? Ink.primary : Ink.secondary)
                        .fixedSize()
                }
                .accessibilityLabel("Next meeting: \(title), \(minutes <= 15 ? "in \(minutes) minutes" : "at \(time)")")
            case .focusTask(let title):
                Group {
                    if compact {
                        Image(systemName: "scope").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.focus)
                    } else {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .truncationMode(.tail)
                    }
                }
                .accessibilityLabel("Focusing on \(title)")
            case .focusRounds(let round, let rounds):
                HStack(spacing: 7) {
                    if !compact {
                        Text("Focus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                    }
                    RoundDots(round: round, rounds: rounds, tint: Ink.focus)
                }
                .accessibilityLabel("Focus, round \(round) of \(rounds)")
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
    }

    private func label(title: String, time: String?, urgency: LeftSignal.Urgency) -> String {
        let when = time.map { " at \($0)" } ?? ""
        switch urgency {
        case .ringing: return "Reminder: \(title)\(when)"
        case .late: return "Overdue: \(title)"
        case .normal: return "Up next: \(title)\(when)"
        }
    }
}

/// Now: the active color — orange for a focus round, blue for a break or a meeting.
private struct RightWing: View {
    let signal: RightSignal
    var compact = false

    var body: some View {
        Group {
            switch signal {
            case .timer(let phase, let remaining, let progress, let paused):
                let tint = phase.isBreak ? Ink.accent : Ink.focus
                HStack(spacing: 6) {
                    if paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 13, height: 13)
                    } else {
                        ProgressRing(progress: progress, tint: tint)
                            .frame(width: 13, height: 13)
                    }
                    if !compact {
                        Text(phase.isBreak ? "Break" : "Focus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(DurationText.countdown(remaining))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .fixedSize()
                }
                .foregroundStyle(paused ? Ink.secondary : tint)
                .accessibilityLabel("\(phase.label)\(paused ? ", paused" : ""), \(DurationText.short(remaining)) left")
            case .meeting(let title, let minutesLeft):
                HStack(spacing: 6) {
                    if compact {
                        Image(systemName: "person.2.fill").font(.system(size: 10, weight: .semibold))
                    } else {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .truncationMode(.tail)
                    }
                    Text("\(minutesLeft)m")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .fixedSize()
                }
                .foregroundStyle(Ink.accent)
                .accessibilityLabel("In \(title), \(minutesLeft) minutes left")
            case .doing(let title, let others):
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: compact ? 11 : 9, weight: .bold))
                    if !compact {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .truncationMode(.tail)
                    }
                    if others > 0 {
                        Text("+\(others)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .fixedSize()
                    }
                }
                .foregroundStyle(Ink.accent)
                .accessibilityLabel("Doing \(title)\(others > 0 ? ", and \(others) more" : "")")
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
    }
}

/// The focus session's progress along the bottom edge of the closed notch. The middle runs
/// behind the camera, so on screen it reads as two lines filling outward from the left.
private struct FocusLine: View {
    let progress: Double
    let paused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.focus.opacity(0.18))
                Capsule()
                    .fill(paused ? Ink.secondary : Ink.focus)
                    .frame(width: max(2, geo.size.width * progress))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// One dot per round: filled through the current round (or the one just finished, during its break).
struct RoundDots: View {
    let round: Int
    let rounds: Int
    var tint: Color = Ink.focus
    var size: CGFloat = 5

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(1...max(1, rounds), id: \.self) { i in
                Circle()
                    .fill(i <= round ? tint : Ink.primary.opacity(0.22))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ProgressRing: View {
    let progress: Double
    var tint: Color = Ink.accent

    var body: some View {
        ZStack {
            Circle().stroke(Ink.hairline, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
