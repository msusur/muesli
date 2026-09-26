import Foundation
import MuesliActions
import MuesliCore

private let ledgerFileName = "applied.json"

private func resolveSession(_ path: String, needing file: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw UsageError("no such file or folder: \(path)")
    }
    let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.appending(path: file).path) else {
        throw UsageError("\(directory.path) has no \(file). Run `muesli summarize` on it first.")
    }
    return directory
}

private func loadLedger(_ directory: URL) -> AppliedLedger {
    (try? Data(contentsOf: directory.appending(path: ledgerFileName))).flatMap { try? AppliedLedger.load(jsonData: $0) } ?? AppliedLedger()
}

private func saveLedger(_ ledger: AppliedLedger, to directory: URL) throws {
    try ledger.jsonData().write(to: directory.appending(path: ledgerFileName))
}

private func isInteractive() -> Bool { isatty(STDIN_FILENO) != 0 }

/// Asks a question on stderr (so stdout stays clean) and reads one line.
private func ask(_ prompt: String) -> String? {
    fputs(prompt, stderr)
    return readLine()
}

// MARK: - actions

struct ActionsCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        guard let path = options.positional.first else {
            throw UsageError("actions needs a session folder (or its notes.json)")
        }
        let directory = try resolveSession(path, needing: "notes.json")
        let notes: MeetingNotes
        do { notes = try MeetingNotes.load(jsonData: Data(contentsOf: directory.appending(path: "notes.json"))) } catch {
            throw UsageError("notes.json isn't readable: \(error.localizedDescription)")
        }

        var ledger = loadLedger(directory)
        var plan = ActionPlan(notes: notes, ledger: options.has("--force") ? AppliedLedger() : ledger)
        if let only = options.value("--only") { plan.actions = try filter(plan.actions, only: only) }

        printReview(plan, notes: notes)
        guard !plan.actions.isEmpty else { return }
        if options.has("--dry-run") { return }

        guard let chosen = try choose(from: plan.actions) else { return }
        let selected = plan.actions.enumerated().filter { chosen.contains($0.offset + 1) }.map(\.element)
        guard !selected.isEmpty else {
            fputs("Nothing selected. Nothing was created.\n", stderr)
            return
        }

        let applier = EventKitApplier(configuration: .init(remindersList: options.value("--reminders-list"), calendar: options.value("--calendar")))
        var denied = Set<ProposedAction.Kind>()
        for (kind, reminders, events) in [(ProposedAction.Kind.reminder, true, false), (.event, false, true)]
        where selected.contains(where: { $0.kind == kind }) {
            do { try await applier.requestAccess(reminders: reminders, events: events) } catch {
                fputs("✗ \(error.localizedDescription)\n", stderr)
                denied.insert(kind)
            }
        }

        var failures = 0
        fputs("\n", stderr)
        for action in selected {
            if denied.contains(action.kind) { failures += 1; continue }
            do {
                let externalID: String
                switch action.payload {
                case .reminder(let request): externalID = try await applier.createReminder(request)
                case .event(let request): externalID = try await applier.createEvent(request)
                case .email(let request): try openMailDraft(request); externalID = ""
                }
                ledger.record(action, externalID: externalID)
                try saveLedger(ledger, to: directory) // after each item, so a crash never loses track
                fputs("✓ \(verb(action.kind)) “\(action.title)”\n", stderr)
            } catch {
                fputs("✗ “\(action.title)”: \(error.localizedDescription)\n", stderr)
                failures += 1
            }
        }
        if selected.contains(where: { $0.kind != .email }) {
            fputs("\nAdded items can be removed with: muesli undo \"\(directory.path)\"\n", stderr)
        }
        if failures > 0 { throw ExitFailure() }
    }

    private func verb(_ kind: ProposedAction.Kind) -> String {
        switch kind {
        case .reminder: "Added reminder"
        case .event: "Added event"
        case .email: "Opened draft"
        }
    }

    // MARK: Review

    private func filter(_ actions: [ProposedAction], only: String) throws -> [ProposedAction] {
        let names: [String: ProposedAction.Kind] = [
            "reminders": .reminder, "reminder": .reminder,
            "events": .event, "event": .event, "calendar": .event,
            "emails": .email, "email": .email, "drafts": .email,
        ]
        let kinds = try only.split(separator: ",").map { token -> ProposedAction.Kind in
            guard let kind = names[token.trimmingCharacters(in: .whitespaces).lowercased()] else {
                throw UsageError("--only takes a comma-separated list of: reminders, events, emails")
            }
            return kind
        }
        return actions.filter { kinds.contains($0.kind) }
    }

    private func printReview(_ plan: ActionPlan, notes: MeetingNotes) {
        let date = notes.meetingStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        print("Proposed from “\(notes.title)” · \(date)")

        var lastKind: ProposedAction.Kind?
        for (index, action) in plan.actions.enumerated() {
            if action.kind != lastKind {
                lastKind = action.kind
                let note = action.kind == .email ? " (opened in your mail app; never sent)" : ""
                print("\n\(action.kind.heading)\(note)")
            }
            let box = action.selectedByDefault ? "[x]" : "[ ]"
            print("  \(box) \(index + 1). \(action.title)" + (action.detail.isEmpty ? "" : " — \(action.detail)"))
        }
        if plan.actions.isEmpty { print("\nNothing new to add.") }

        if !plan.skipped.isEmpty {
            print("\nNot proposed:")
            for item in plan.skipped { print("  - \(item.kind.rawValue) “\(item.title)”: \(item.reason)") }
        }
        if !plan.alreadyApplied.isEmpty {
            print("\nAlready added earlier: \(plan.alreadyApplied.count) item\(plan.alreadyApplied.count == 1 ? "" : "s") (use --force to add again)")
        }
        print("")
    }

    /// Which items to apply (1-based), or nil if we should stop. Never applies
    /// anything without either an interactive answer or an explicit flag.
    private func choose(from actions: [ProposedAction]) throws -> Set<Int>? {
        let defaults = Set(actions.enumerated().filter { $0.element.selectedByDefault }.map { $0.offset + 1 })
        if options.has("--all") { return Set(1 ... actions.count) }
        if options.has("--yes") { return defaults }
        guard isInteractive() else {
            fputs("Not applying anything: this isn't an interactive terminal. Re-run with --yes (checked items) or --all.\n", stderr)
            throw ExitFailure()
        }
        while true {
            guard let answer = ask("Add which? [Enter = checked · a = all · n = none · or numbers like 1,3-4]: ") else { return nil }
            if let chosen = ReviewSelection.parse(answer, count: actions.count, defaults: defaults) { return chosen }
            fputs("Didn't understand “\(answer)”. Use numbers 1–\(actions.count), a, or n.\n", stderr)
        }
    }

    /// Opens a pre-filled compose window in the default mail client. Muesli
    /// never sends mail.
    private func openMailDraft(_ email: EmailRequest) throws {
        guard let url = MailDraft.mailtoURL(to: email.recipients, subject: email.subject, body: email.body) else {
            throw UsageError("couldn't build a mail link for “\(email.subject)”")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageError("couldn't open your mail app (open exited \(process.terminationStatus))")
        }
    }
}

// MARK: - undo

struct UndoCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        guard let path = options.positional.first else { throw UsageError("undo needs a session folder") }
        let directory = try resolveSession(path, needing: ledgerFileName)
        var ledger = loadLedger(directory)
        let removable = ledger.entries.filter { $0.kind != .email && !$0.externalID.isEmpty }
        guard !removable.isEmpty else {
            print("Nothing to undo. (Email drafts can't be undone; close them in your mail app.)")
            return
        }

        print("muesli added these:")
        for entry in removable { print("  - \(entry.kind == .reminder ? "reminder" : "event"): \(entry.title)") }
        if !options.has("--yes") {
            guard isInteractive(), let answer = ask("\nRemove them? [y/N]: "), answer.lowercased().hasPrefix("y") else {
                fputs("Nothing removed.\n", stderr)
                return
            }
        }

        let applier = EventKitApplier()
        try await applier.requestAccess(reminders: removable.contains { $0.kind == .reminder }, events: removable.contains { $0.kind == .event })

        var failures = 0
        for entry in removable {
            do {
                let removed = try await applier.remove(kind: entry.kind, identifier: entry.externalID)
                ledger.remove(key: entry.key)
                try saveLedger(ledger, to: directory)
                fputs(removed ? "✓ Removed “\(entry.title)”\n" : "• “\(entry.title)” was already gone\n", stderr)
            } catch {
                fputs("✗ “\(entry.title)”: \(error.localizedDescription)\n", stderr)
                failures += 1
            }
        }
        if failures > 0 { throw ExitFailure() }
    }
}
