import AppKit
import EventKit
import NotchCore
import Observation

/// Reads events from the macOS Calendar database — every account added in
/// System Settings › Internet Accounts (Google, iCloud, Exchange) shows up here.
@Observable
final class CalendarStore {
    enum Access: Equatable {
        case unknown
        case granted
        case denied
    }

    private(set) var access: Access = .unknown
    private(set) var events: [TimedEvent] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var changes: Task<Void, Never>?
    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
    }

    /// Fixed data for `--render-previews`; never touches the calendar database.
    init(previewAccess: Access, events: [TimedEvent]) {
        isPreview = true
        access = previewAccess
        self.events = events
    }

    func start() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            reload()
        case .notDetermined:
            requestAccess()
        default:
            access = .denied
        }

        changes = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                self?.reload()
            }
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.access = granted ? .granted : .denied
                if granted { self.reload() }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Events from 12 hours ago through the end of tomorrow.
    func reload(now: Date = .now) {
        guard access == .granted, !isPreview else { return }
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .hour, value: -12, to: now),
              let to = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                TimedEvent(
                    id: event.eventIdentifier ?? "\(event.title ?? "")-\(event.startDate.timeIntervalSince1970)",
                    title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled event",
                    start: event.startDate,
                    end: event.endDate
                )
            }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
