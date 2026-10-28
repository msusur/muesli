import Foundation
import MuesliActions
import MuesliCore

/// Adds approved actions to Reminders, Calendar and the mail app, and removes
/// them again. Records everything in the session's ledger as it goes, so a crash
/// never loses track of what was added.
public struct ActionRunner: Sendable {
    public struct Outcome: Sendable, Identifiable {
        public var id: UUID { action.id }
        public var action: ProposedAction
        /// `nil` on success.
        public var error: String?
        public var succeeded: Bool { error == nil }
    }

    public struct UndoOutcome: Sendable {
        public var title: String
        /// `false` if it had already been deleted by hand.
        public var removed: Bool
        public var error: String?
    }

    public let folder: SessionFolder
    public let configuration: EventKitApplier.Configuration

    public init(folder: SessionFolder, configuration: EventKitApplier.Configuration = .init()) {
        self.folder = folder
        self.configuration = configuration
    }

    /// The proposals for this session. With `force`, items added before are proposed again.
    public func plan(force: Bool = false) throws -> (plan: ActionPlan, notes: MeetingNotes) {
        let notes = try folder.loadNotes()
        return (ActionPlan(notes: notes, ledger: force ? AppliedLedger() : folder.loadLedger()), notes)
    }

    /// Applies `selected` in order. Never throws for a single item; each outcome says how it went.
    public func apply(_ selected: [ProposedAction]) async -> [Outcome] {
        let applier = EventKitApplier(configuration: configuration)
        var ledger = folder.loadLedger()

        var denied: [ProposedAction.Kind: String] = [:]
        for (kind, reminders, events) in [(ProposedAction.Kind.reminder, true, false), (.event, false, true)]
        where selected.contains(where: { $0.kind == kind }) {
            do { try await applier.requestAccess(reminders: reminders, events: events) } catch {
                denied[kind] = error.localizedDescription
            }
        }

        var outcomes: [Outcome] = []
        for action in selected {
            if let why = denied[action.kind] {
                outcomes.append(Outcome(action: action, error: why))
                continue
            }
            do {
                let externalID: String
                switch action.payload {
                case .reminder(let request): externalID = try await applier.createReminder(request)
                case .event(let request): externalID = try await applier.createEvent(request)
                case .email(let request): try Self.openMailDraft(request); externalID = ""
                }
                ledger.record(action, externalID: externalID)
                try folder.saveLedger(ledger)
                outcomes.append(Outcome(action: action, error: nil))
            } catch {
                outcomes.append(Outcome(action: action, error: error.localizedDescription))
            }
        }
        return outcomes
    }

    /// What `undo()` would remove: reminders and events muesli added. Mail drafts can't be undone.
    public func undoable() -> [AppliedLedger.Entry] {
        folder.loadLedger().entries.filter { $0.kind != .email && !$0.externalID.isEmpty }
    }

    public func undo() async throws -> [UndoOutcome] {
        var ledger = folder.loadLedger()
        let removable = undoable()
        guard !removable.isEmpty else { return [] }

        let applier = EventKitApplier()
        try await applier.requestAccess(
            reminders: removable.contains { $0.kind == .reminder }, events: removable.contains { $0.kind == .event })

        var outcomes: [UndoOutcome] = []
        for entry in removable {
            do {
                let removed = try await applier.remove(kind: entry.kind, identifier: entry.externalID)
                ledger.remove(key: entry.key)
                try folder.saveLedger(ledger)
                outcomes.append(UndoOutcome(title: entry.title, removed: removed, error: nil))
            } catch {
                outcomes.append(UndoOutcome(title: entry.title, removed: false, error: error.localizedDescription))
            }
        }
        return outcomes
    }

    /// Opens a pre-filled compose window in the default mail client. Muesli never sends mail.
    public static func openMailDraft(_ email: EmailRequest) throws {
        guard let url = MailDraft.mailtoURL(to: email.recipients, subject: email.subject, body: email.body) else {
            throw ActionRunnerError("couldn't build a mail link for “\(email.subject)”")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ActionRunnerError("couldn't open your mail app (open exited \(process.terminationStatus))")
        }
    }
}

public struct ActionRunnerError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
