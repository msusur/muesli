import Foundation

// MARK: - Requests (what the platform layer is asked to create)

public struct ReminderRequest: Sendable, Equatable {
    public var title: String
    public var notes: String
    /// Year/month/day only: a date-only reminder, independent of time zone.
    public var due: DateComponents?
}

public struct EventRequest: Sendable, Equatable {
    public var title: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: TimeZone
}

public struct EmailRequest: Sendable, Equatable {
    /// Only entries that are real email addresses.
    public var recipients: [String]
    /// Names the speakers used ("Board", "Sarah") with no address known.
    public var unresolvedNames: [String]
    public var subject: String
    public var body: String
}

// MARK: - Proposed action

/// One thing muesli suggests doing with the notes. Nothing is created until a
/// person has reviewed the plan.
public struct ProposedAction: Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case reminder, event, email

        public var heading: String {
            switch self {
            case .reminder: "Reminders"
            case .event: "Calendar"
            case .email: "Email drafts"
            }
        }
    }

    public enum Payload: Sendable, Equatable {
        case reminder(ReminderRequest)
        case event(EventRequest)
        case email(EmailRequest)
    }

    public var id: UUID
    public var kind: Kind
    /// Stable across re-summarizing the same meeting, so the ledger can tell an
    /// item has already been created even if its `id` changed.
    public var key: String
    public var title: String
    /// One line for the review list: when, who, where it goes.
    public var detail: String
    public var selectedByDefault: Bool
    public var payload: Payload
}

public struct SkippedItem: Sendable, Equatable {
    public var kind: ProposedAction.Kind
    public var title: String
    public var reason: String
}

// MARK: - Plan

public struct ActionPlan: Sendable, Equatable {
    /// Things not yet created, in review order: reminders, events, emails.
    public var actions: [ProposedAction]
    /// Things that were already created by an earlier run.
    public var alreadyApplied: [ProposedAction]
    /// Things muesli couldn't turn into an action, with the reason.
    public var skipped: [SkippedItem]

    public init(notes: MeetingNotes, ledger: AppliedLedger = AppliedLedger()) {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: notes.timeZoneIdentifier) ?? .current
        calendar.timeZone = timeZone
        let source = Source(notes: notes, calendar: calendar, timeZone: timeZone)

        var all: [ProposedAction] = []
        var skipped: [SkippedItem] = []
        all += notes.actionItems.map { source.reminder($0) }
        for event in notes.events {
            if let action = source.event(event) { all.append(action) } else {
                skipped.append(SkippedItem(kind: .event, title: event.title, reason: "no date or time was given, so it can't go in a calendar"))
            }
        }
        all += notes.emailDrafts.map { source.email($0) }

        self.actions = all.filter { !ledger.contains(key: $0.key) }
        self.alreadyApplied = all.filter { ledger.contains(key: $0.key) }
        self.skipped = skipped
    }

    public var isEmpty: Bool { actions.isEmpty }
}

/// Turns validated notes into concrete requests.
private struct Source {
    let notes: MeetingNotes
    let calendar: Calendar
    let timeZone: TimeZone

    /// "Launch sync" (Fri 25 Sep 2026): where an item came from, for its notes field.
    var provenance: String {
        "From “\(notes.title)” (\(Self.format(notes.meetingStart, "EEE d MMM yyyy", timeZone))), created by muesli."
    }

    func reminder(_ item: MeetingNotes.ActionItem) -> ProposedAction {
        let mine = item.owner == nil || item.owner == "Me"
        let due = item.dueDate.flatMap(dateComponents)

        var lines: [String] = []
        if let context = item.context { lines.append(context) }
        if let spoken = item.dueText { lines.append("Said: “\(spoken)”") }
        lines.append(provenance)

        var detailParts: [String] = []
        if let due, let date = calendar.date(from: due) { detailParts.append("due " + Self.format(date, "EEE d MMM", timeZone)) }
        else if let spoken = item.dueText { detailParts.append("no date resolved (“\(spoken)”)") }
        if let owner = item.owner { detailParts.append(owner) }

        let title = mine ? item.title : "Waiting on \(item.owner ?? "someone"): \(item.title)"
        return ProposedAction(
            id: item.id, kind: .reminder,
            key: "reminder|\(Self.normalize(item.title))|\(item.dueDate ?? "")",
            title: title, detail: detailParts.joined(separator: " · "),
            // Only your own tasks go on your list by default; other people's are
            // offered as "waiting on" reminders.
            selectedByDefault: mine,
            payload: .reminder(ReminderRequest(title: title, notes: lines.joined(separator: "\n"), due: due))
        )
    }

    func event(_ e: MeetingNotes.EventSuggestion) -> ProposedAction? {
        guard let startText = e.start else { return nil }
        let datePart = String(startText.prefix(10))
        guard let day = dateComponents(datePart), let dayStart = calendar.date(from: day) else { return nil }

        let start: Date
        let end: Date
        let isAllDay = !e.hasTime
        if isAllDay {
            start = dayStart
            end = dayStart
        } else {
            let time = startText.dropFirst(11).split(separator: ":").compactMap { Int($0) }
            guard time.count >= 2,
                  let s = calendar.date(from: DateComponents(
                      year: day.year, month: day.month, day: day.day, hour: time[0], minute: time[1]))
            else { return nil }
            start = s
            end = s.addingTimeInterval(TimeInterval((e.durationMinutes ?? 30) * 60))
        }

        var lines: [String] = []
        if !e.attendees.isEmpty { lines.append("With: " + e.attendees.joined(separator: ", ")) }
        lines.append(provenance)

        let when = isAllDay
            ? Self.format(start, "EEE d MMM", timeZone) + " (all day)"
            : Self.format(start, "EEE d MMM, HH:mm", timeZone) + "–" + Self.format(end, "HH:mm", timeZone)
        var detail = when
        if !e.attendees.isEmpty { detail += " · with " + e.attendees.joined(separator: ", ") }

        return ProposedAction(
            id: e.id, kind: .event,
            key: "event|\(Self.normalize(e.title))|\(startText)",
            title: e.title, detail: detail, selectedByDefault: true,
            payload: .event(EventRequest(
                title: e.title, notes: lines.joined(separator: "\n"),
                start: start, end: end, isAllDay: isAllDay, timeZone: timeZone))
        )
    }

    func email(_ m: MeetingNotes.EmailDraft) -> ProposedAction {
        let recipients = m.to.filter(MailDraft.isEmailAddress)
        let names = m.to.filter { !MailDraft.isEmailAddress($0) }
        var detail = recipients.isEmpty ? "no recipient address yet" : "to " + recipients.joined(separator: ", ")
        if !names.isEmpty { detail += " · add an address for " + names.joined(separator: ", ") }
        let subject = m.subject.isEmpty ? "(no subject)" : m.subject
        return ProposedAction(
            id: m.id, kind: .email,
            key: "email|\(Self.normalize(m.subject))|\(Self.normalize(String(m.body.prefix(40))))",
            title: subject, detail: detail, selectedByDefault: true,
            payload: .email(EmailRequest(recipients: recipients, unresolvedNames: names, subject: m.subject, body: m.body))
        )
    }

    private func dateComponents(_ iso: String) -> DateComponents? {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

// MARK: - Ledger

/// Remembers what has already been created for a meeting, so running `actions`
/// twice never duplicates reminders or events, and so `undo` knows what to remove.
public struct AppliedLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var key: String
        public var kind: ProposedAction.Kind
        public var title: String
        /// EventKit's identifier for reminders and events; empty for email drafts.
        public var externalID: String
        public var createdAt: Date
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func contains(key: String) -> Bool { entries.contains { $0.key == key } }

    public mutating func record(_ action: ProposedAction, externalID: String, at date: Date = Date()) {
        entries.removeAll { $0.key == action.key }
        entries.append(Entry(key: action.key, kind: action.kind, title: action.title, externalID: externalID, createdAt: date))
    }

    public mutating func remove(key: String) {
        entries.removeAll { $0.key == key }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func load(jsonData data: Data) throws -> AppliedLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppliedLedger.self, from: data)
    }
}

// MARK: - Review selection

/// Parses what a person types at the review prompt.
public enum ReviewSelection {
    /// Numbers are 1-based positions in the review list. Returns nil for input
    /// it can't understand, so the caller can ask again rather than guess.
    public static func parse(_ input: String, count: Int, defaults: Set<Int>) -> Set<Int>? {
        guard count > 0 else { return [] }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "": return defaults
        case "a", "all": return Set(1 ... count)
        case "n", "none", "q", "quit": return []
        default: break
        }

        var chosen = Set<Int>()
        for token in text.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            switch bounds.count {
            case 1:
                guard let n = Int(bounds[0]), (1 ... count).contains(n) else { return nil }
                chosen.insert(n)
            case 2:
                guard let a = Int(bounds[0]), let b = Int(bounds[1]), a <= b, a >= 1, b <= count else { return nil }
                chosen.formUnion(a ... b)
            default:
                return nil
            }
        }
        return chosen.isEmpty ? nil : chosen
    }
}

// MARK: - Mail drafts

public enum MailDraft {
    /// A conservative "looks like an address" check; we never invent addresses.
    public static func isEmailAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.contains(where: \.isWhitespace), let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }

    /// A `mailto:` URL that opens a pre-filled compose window in the user's
    /// default mail client. It can only *open a draft*: nothing is ever sent
    /// without the person pressing Send. Everything is percent-encoded, and the
    /// body is model output derived from a transcript, so it is never
    /// interpolated into a script or shell command.
    public static func mailtoURL(to: [String], subject: String, body: String) -> URL? {
        let recipients = to.filter(isEmailAddress).map { encode($0, allowing: "@+") }.joined(separator: ",")
        var query: [String] = []
        if !subject.isEmpty { query.append("subject=" + encode(subject)) }
        if !body.isEmpty { query.append("body=" + encode(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))) }
        return URL(string: "mailto:" + recipients + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    private static func encode(_ s: String, allowing extra: String = "") -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~" + extra)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
