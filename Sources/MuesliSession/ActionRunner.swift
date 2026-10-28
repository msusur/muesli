import Foundation
import MuesliCore

/// Opens approved email drafts in the mail app. Records each one in the
/// session's ledger as it goes, so running it again doesn't open them twice.
public struct ActionRunner: Sendable {
    public struct Outcome: Sendable, Identifiable {
        public var id: UUID { action.id }
        public var action: ProposedAction
        /// `nil` on success.
        public var error: String?
        public var succeeded: Bool { error == nil }
    }

    public let folder: SessionFolder

    public init(folder: SessionFolder) {
        self.folder = folder
    }

    /// The proposals for this session. With `force`, drafts opened before are proposed again.
    public func plan(force: Bool = false) throws -> (plan: ActionPlan, notes: MeetingNotes) {
        let notes = try folder.loadNotes()
        return (ActionPlan(notes: notes, ledger: force ? AppliedLedger() : folder.loadLedger()), notes)
    }

    /// Applies `selected` in order. Never throws for a single item; each outcome says how it went.
    public func apply(_ selected: [ProposedAction]) async -> [Outcome] {
        var ledger = folder.loadLedger()
        var outcomes: [Outcome] = []
        for action in selected {
            do {
                switch action.payload {
                case .email(let request): try Self.openMailDraft(request)
                }
                ledger.record(action, externalID: "")
                try folder.saveLedger(ledger)
                outcomes.append(Outcome(action: action, error: nil))
            } catch {
                outcomes.append(Outcome(action: action, error: error.localizedDescription))
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
