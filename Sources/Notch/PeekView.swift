import NotchCore
import SwiftUI

/// A banner the notch drops on its own. The band beside the camera says what kind and when;
/// below it, one line and at most two actions. Click the text to open the full notch.
struct PeekView: View {
    let alert: NotchAlert
    let model: NotchModel
    let metrics: NotchMetrics

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind)
                Spacer(minLength: metrics.notchSize.width + 20)
                Text(when)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .frame(height: metrics.notchSize.height)

            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(symbolTint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.expandNotch?() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the notch")

                actions
            }
            .frame(height: NotchMetrics.peekContentHeight - 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24 + NotchMetrics.radii(.peek).top)
        .frame(width: metrics.shapeSize(.peek).width, height: metrics.shapeSize(.peek).height, alignment: .top)
    }

    @ViewBuilder
    private var actions: some View {
        switch alert {
        case .reminder(let id, _, _), .due(let id, _, _):
            HStack(spacing: 8) {
                Button("Snooze") { model.snoozeFromAlert(id) }
                    .buttonStyle(PeekButtonStyle(prominent: false))
                    .help("Remind me again in 10 minutes")
                Button("Done") { model.completeFromAlert(id) }
                    .buttonStyle(PeekButtonStyle(prominent: true))
            }
        case .reminders:
            Button("Show") { model.expandNotch?() }
                .buttonStyle(PeekButtonStyle(prominent: true))
        case .focusEnded:
            Button("Skip break") { model.skipPhase(); model.dismissAlert() }
                .buttonStyle(PeekButtonStyle(prominent: false))
        case .breakEnded(let round, _, _):
            Button("Start round \(round)") { model.startFocus() }
                .buttonStyle(PeekButtonStyle(prominent: true))
        case .planDay:
            Button("Plan") { model.dismissAlert(); model.openPlanner() }
                .buttonStyle(PeekButtonStyle(prominent: true))
        case .wrapUpDay:
            Button("Wrap up") { model.dismissAlert(); model.openPlanner() }
                .buttonStyle(PeekButtonStyle(prominent: true))
        case .nudge(let nudge, _):
            HStack(spacing: 8) {
                if nudge.duringFocus {
                    Button("It's work") { model.snoozeNudges(minutes: 60) }
                        .buttonStyle(PeekButtonStyle(prominent: false))
                        .help("No nudges for an hour")
                    Button("Back to it") { model.dismissAlert() }
                        .buttonStyle(PeekButtonStyle(prominent: true))
                } else {
                    Button("Snooze") { model.snoozeNudges(minutes: 15) }
                        .buttonStyle(PeekButtonStyle(prominent: false))
                        .help("No nudges for 15 minutes")
                    Button("Start focus") { model.dismissAlert(); model.startFocus() }
                        .buttonStyle(PeekButtonStyle(prominent: true))
                        .help("Start a focus round on what's in Doing")
                }
            }
        case .eventSoon:
            EmptyView()
        }
    }

    private var kind: String {
        switch alert {
        case .reminder, .reminders: "Reminder"
        case .due: "Due now"
        case .eventSoon: "Calendar"
        case .focusEnded, .breakEnded: "Pomodoro"
        case .planDay, .wrapUpDay: "Planner"
        case .nudge(let nudge, _): nudge.duringFocus ? "Focus mode" : "Focus check"
        }
    }

    private var when: String {
        switch alert {
        case .reminder(_, _, let at), .due(_, _, let at):
            TimeText.clock(at, calendar: .current)
        case .eventSoon(_, _, let start):
            "in \(max(1, Int((start.timeIntervalSince(model.now) / 60).rounded(.up))))m"
        case .reminders:
            ""
        case .focusEnded(let round, let rounds, _, _, _):
            "Round \(round) of \(rounds)"
        case .breakEnded(let round, let rounds, _):
            "Round \(round) of \(rounds)"
        case .planDay, .wrapUpDay:
            model.now.formatted(.dateTime.weekday(.wide))
        case .nudge(let nudge, _):
            "\(nudge.minutes)m"
        }
    }

    private var symbolTint: Color {
        if case .nudge(let nudge, _) = alert, nudge.duringFocus { return Ink.focus }
        return Ink.accent
    }

    private var symbol: String {
        switch alert {
        case .reminder, .reminders: "bell.fill"
        case .due: "flag.fill"
        case .eventSoon: "calendar"
        case .focusEnded: "cup.and.saucer.fill"
        case .breakEnded: "timer"
        case .planDay: "sun.max.fill"
        case .wrapUpDay: "sunset.fill"
        case .nudge(let nudge, _):
            switch nudge.source.kind {
            case .game: "gamecontroller.fill"
            case .video: "play.rectangle.fill"
            case .social, .workSocial: "bubble.left.and.bubble.right.fill"
            }
        }
    }

    private var title: String {
        switch alert {
        case .reminder(_, let title, _), .due(_, let title, _), .eventSoon(_, let title, _): title
        case .reminders(let count): "\(count) reminders went off"
        case .focusEnded(_, _, _, let isLong, _): isLong ? "All rounds done. Take a long break" : "Focus done. Take a break"
        case .breakEnded: "Break's over"
        case .planDay: "Plan your day"
        case .wrapUpDay: "Wrap up your day"
        case .nudge(let nudge, _):
            nudge.duringFocus ? "You're in a focus round" : "\(nudge.minutes) min on \(nudge.source.name)"
        }
    }

    private var subtitle: String? {
        switch alert {
        case .reminder(let id, _, _):
            guard let task = model.tasks.task(id) else { return nil }
            if let due = task.due { return "Due \(TaskRules.dueLabel(due, now: model.now, calendar: .current))" }
            return model.tasks.project(task.projectID)?.name
        case .due(let id, _, _):
            return model.tasks.task(id).flatMap { model.tasks.project($0.projectID)?.name }
        case .eventSoon(_, _, let start):
            return "Starts at \(TimeText.clock(start, calendar: .current))"
        case .reminders:
            return "Open the notch to go through them"
        case .focusEnded(_, _, let minutes, _, _):
            return "\(minutes)-minute break started"
        case .breakEnded:
            return "Start the next focus round when you're ready"
        case .planDay:
            let due = TaskRules.today(model.tasks.tasks, now: model.now, calendar: .current).count
            return "\(DurationText.short(TimeInterval(model.dayTime.free * 60))) free · \(due) due today · pick up to 3"
        case .wrapUpDay:
            let picks = model.todayPicks
            return "\(picks.filter(\.isDone).count) of \(picks.count) planned done"
        case .nudge(let nudge, _):
            if nudge.duringFocus {
                let left = model.pomodoro.remaining(at: model.now).map { DurationText.short($0) } ?? ""
                return "\(nudge.source.name) for \(nudge.minutes)m · \(left) left in the round"
            }
            if let doing = model.doingTasks.first { return "Up now: \(doing.title)" }
            return "Your plan is waiting"
        }
    }
}

private struct PeekButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .fixedSize()
            .foregroundStyle(prominent ? Color.black : Ink.primary)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(Capsule().fill(prominent ? Ink.primary : Ink.primary.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
