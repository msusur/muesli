import EventKit
import Foundation

/// The calendar event happening now or about to start, to offer
/// "Record “Weekly sync”" and use its title for the notes.
struct UpcomingMeeting: Equatable {
    let title: String
    let start: Date
    let end: Date

    @MainActor private static let store = EKEventStore()

    /// The meeting in progress, or the next one starting within 15 minutes.
    /// Never asks for access; returns `nil` until Calendar access is granted.
    @MainActor static func next(now: Date = Date()) -> UpcomingMeeting? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(15 * 60), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && !declined($0) && !($0.title ?? "").isEmpty }
            // Prefer what started most recently (the meeting you're in), else the soonest.
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
            .map { UpcomingMeeting(title: $0.title, start: $0.startDate, end: $0.endDate) }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    @MainActor static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    var when: String {
        let now = Date()
        if start <= now { return "now, until \(end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return "starts in \(minutes) min"
    }
}
