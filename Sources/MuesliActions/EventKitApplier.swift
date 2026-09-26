import EventKit
import Foundation
import MuesliCore

/// Creates and removes Reminders and Calendar events with EventKit.
///
/// Uses *full* access to both: Reminders has no write-only mode, and full
/// Calendar access is what lets muesli find a calendar by name and undo what it
/// created. It never reads your other items.
public actor EventKitApplier {
    public struct Configuration: Sendable {
        /// Reminders list to add to; nil = your default list.
        public var remindersList: String?
        /// Calendar to add events to; nil = your default calendar.
        public var calendar: String?

        public init(remindersList: String? = nil, calendar: String? = nil) {
            self.remindersList = remindersList
            self.calendar = calendar
        }
    }

    public enum Access: String, Sendable {
        case granted, notDetermined, denied, restricted, writeOnly
    }

    public enum ActionError: Error, LocalizedError, Equatable {
        case accessDenied(what: String)
        /// Calendar is write-only: events can be added but not looked up or removed.
        case needsFullCalendarAccess(String)
        case noDefault(what: String)
        case notFound(kind: String, name: String, available: [String])
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .accessDenied(let what):
                "Access to \(what) was denied. Allow it for your terminal in System Settings → Privacy & Security → \(what)."
            case .needsFullCalendarAccess(let action):
                "\(action) needs full Calendar access, but muesli only has write-only access. Grant full access to your terminal in System Settings → Privacy & Security → Calendars."
            case .noDefault(let what):
                "You have no default \(what). Open the app once and set one up, or pass a name."
            case .notFound(let kind, let name, let available):
                "No writable \(kind) named “\(name)”." + (available.isEmpty ? "" : " Available: " + available.sorted().joined(separator: ", ") + ".")
            case .saveFailed(let why):
                "Couldn't save: \(why)"
            }
        }
    }

    private let store = EKEventStore()
    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Access

    /// Current permission, without prompting.
    public static func access(for entity: ProposedAction.Kind) -> Access {
        switch EKEventStore.authorizationStatus(for: entity == .reminder ? .reminder : .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    /// Asks for what's needed (this is what shows the system permission prompt,
    /// once). Throws if either is refused.
    public func requestAccess(reminders: Bool, events: Bool) async throws {
        if reminders, Self.access(for: .reminder) != .granted {
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            guard granted else { throw ActionError.accessDenied(what: "Reminders") }
        }
        if events {
            switch Self.access(for: .event) {
            case .granted, .writeOnly:
                // Write-only is enough to add events; looking one up by name, or
                // removing it later, is checked where it's needed.
                break
            default:
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                guard granted else { throw ActionError.accessDenied(what: "Calendars") }
            }
        }
    }

    // MARK: Create

    /// Returns EventKit's identifier for the new reminder.
    public func createReminder(_ request: ReminderRequest) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = request.title
        reminder.notes = request.notes
        reminder.calendar = try reminderList()
        if let due = request.due {
            var components = due
            components.calendar = Calendar(identifier: .gregorian)
            reminder.dueDateComponents = components
        }
        do { try store.save(reminder, commit: true) } catch { throw ActionError.saveFailed(error.localizedDescription) }
        return reminder.calendarItemIdentifier
    }

    /// Returns EventKit's identifier for the new event.
    public func createEvent(_ request: EventRequest) throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = request.title
        event.notes = request.notes
        event.calendar = try eventCalendar()
        event.timeZone = request.timeZone
        event.isAllDay = request.isAllDay
        event.startDate = request.start
        event.endDate = request.end
        do { try store.save(event, span: .thisEvent, commit: true) } catch { throw ActionError.saveFailed(error.localizedDescription) }
        return event.eventIdentifier
    }

    // MARK: Remove (undo)

    /// Removes something muesli created. Returns false if it's already gone
    /// (deleted by hand), which isn't an error.
    public func remove(kind: ProposedAction.Kind, identifier: String) throws -> Bool {
        do {
            switch kind {
            case .reminder:
                guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return false }
                try store.remove(reminder, commit: true)
            case .event:
                // Under write-only access lookups return nothing, which would look
                // like "already deleted" while the event is still there.
                guard Self.access(for: .event) == .granted else { throw ActionError.needsFullCalendarAccess("Removing an event") }
                guard let event = store.event(withIdentifier: identifier) else { return false }
                try store.remove(event, span: .thisEvent, commit: true)
            case .email:
                return false
            }
            return true
        } catch {
            throw ActionError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: Lookup

    private func reminderList() throws -> EKCalendar {
        if let name = configuration.remindersList {
            return try named(name, in: store.calendars(for: .reminder), kind: "Reminders list")
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw ActionError.noDefault(what: "Reminders list") }
        return list
    }

    private func eventCalendar() throws -> EKCalendar {
        if let name = configuration.calendar {
            guard Self.access(for: .event) == .granted else { throw ActionError.needsFullCalendarAccess("Choosing a calendar by name") }
            return try named(name, in: store.calendars(for: .event), kind: "calendar")
        }
        guard let calendar = store.defaultCalendarForNewEvents else { throw ActionError.noDefault(what: "calendar") }
        return calendar
    }

    private func named(_ name: String, in calendars: [EKCalendar], kind: String) throws -> EKCalendar {
        let writable = calendars.filter(\.allowsContentModifications)
        if let match = writable.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        throw ActionError.notFound(kind: kind, name: name, available: writable.map(\.title))
    }
}
