import Foundation
import MuesliActions
import MuesliCore
import MuesliSession

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
        let runner = ActionRunner(
            folder: SessionFolder(directory),
            configuration: .init(remindersList: options.value("--reminders-list"), calendar: options.value("--calendar")))
        var plan: ActionPlan
        let notes: MeetingNotes
        do { (plan, notes) = try runner.plan(force: options.has("--force")) } catch {
            throw UsageError("notes.json isn't readable: \(error.localizedDescription)")
        }
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

        fputs("\n", stderr)
        var failures = 0
        for outcome in await runner.apply(selected) {
            if let error = outcome.error {
                fputs("✗ “\(outcome.action.title)”: \(error)\n", stderr)
                failures += 1
            } else {
                fputs("✓ \(verb(outcome.action.kind)) “\(outcome.action.title)”\n", stderr)
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
}

// MARK: - undo

struct UndoCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        guard let path = options.positional.first else { throw UsageError("undo needs a session folder") }
        let directory = try resolveSession(path, needing: SessionFolder.ledgerFile)
        let runner = ActionRunner(folder: SessionFolder(directory))
        let removable = runner.undoable()
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

        var failures = 0
        for outcome in try await runner.undo() {
            if let error = outcome.error {
                fputs("✗ “\(outcome.title)”: \(error)\n", stderr)
                failures += 1
            } else {
                fputs(outcome.removed ? "✓ Removed “\(outcome.title)”\n" : "• “\(outcome.title)” was already gone\n", stderr)
            }
        }
        if failures > 0 { throw ExitFailure() }
    }
}
