import Foundation

/// Where and when a meeting happened, plus what the user typed themselves.
/// This is what lets "by Monday" become an actual date.
public struct MeetingContext: Sendable, Equatable {
    public var title: String?
    public var start: Date
    public var timeZone: TimeZone
    /// The user's own rough notes, if any. Muesli's job is to enhance these.
    public var userNotes: String?

    public init(title: String? = nil, start: Date, timeZone: TimeZone = .current, userNotes: String? = nil) {
        self.title = title
        self.start = start
        self.timeZone = timeZone
        self.userNotes = userNotes
    }

    var hasUserNotes: Bool {
        !(userNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
    }
}

/// Validated notes, ready to show and to turn into mail drafts.
public struct MeetingNotes: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var events: [EventSuggestion]
    public var emailDrafts: [EmailDraft]
    public var openQuestions: [String]
    /// The user's notes, expanded from the transcript. `nil` if they wrote none.
    public var enhancedNotes: String?

    public var meetingStart: Date
    public var timeZoneIdentifier: String
    /// e.g. "anthropic:claude-opus-5". For provenance only.
    public var generatedBy: String

    public struct ActionItem: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        /// "Me", a person's name, or nil when unclear.
        public var owner: String?
        /// `YYYY-MM-DD`, validated. Time zone independent, like a date-only reminder.
        public var dueDate: String?
        public var dueText: String?
        public var context: String?
    }

    public struct EventSuggestion: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        /// `YYYY-MM-DD` (all-day) or `YYYY-MM-DDTHH:mm` in the meeting's time zone; nil if unknown.
        public var start: String?
        public var durationMinutes: Int?
        public var attendees: [String]

        public var hasTime: Bool { start?.contains("T") ?? false }
    }

    public struct EmailDraft: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var to: [String]
        public var subject: String
        public var body: String
    }
}

// MARK: - Persistence

extension MeetingNotes {
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func load(jsonData data: Data) throws -> MeetingNotes {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingNotes.self, from: data)
    }
}

// MARK: - Normalization

extension MeetingNotes {
    /// Validates and cleans model output. Never trusts a model's dates: an
    /// invalid date, or one before the meeting took place, is dropped (the
    /// spoken `dueText` is kept so a human can still see what was said).
    public init(normalizing g: GeneratedNotes, context: MeetingContext, generatedBy: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let meetingDay = ISODate.dayNumber(of: context.start, calendar: calendar)

        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func cleanList(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.compactMap(clean).filter { seen.insert($0.lowercased()).inserted }
        }

        var seenActions = Set<String>()
        let actions: [ActionItem] = g.actionItems.compactMap { a in
            guard let title = clean(a.title), seenActions.insert(title.lowercased()).inserted else { return nil }
            let due = ISODate.validDate(a.dueDate).flatMap { ISODate.dayNumber(of: $0) >= meetingDay ? $0 : nil }
            return ActionItem(
                id: UUID(), title: title, owner: Self.cleanOwner(a.owner),
                dueDate: due, dueText: clean(a.dueText), context: clean(a.context)
            )
        }

        let events: [EventSuggestion] = g.events.compactMap { e in
            guard let title = clean(e.title) else { return nil }
            var start = ISODate.validStart(e.start)
            if let s = start, ISODate.dayNumber(of: String(s.prefix(10))) < meetingDay { start = nil }
            return EventSuggestion(
                id: UUID(), title: title, start: start,
                durationMinutes: e.durationMinutes > 0 ? e.durationMinutes : nil,
                attendees: cleanList(e.attendees).filter { !["me", "myself", "i"].contains($0.lowercased()) }
            )
        }

        let emails: [EmailDraft] = g.emailDrafts.compactMap { m in
            guard let body = clean(m.body) else { return nil }
            return EmailDraft(id: UUID(), to: cleanList(m.to), subject: clean(m.subject) ?? "", body: body)
        }

        self.init(
            title: clean(g.title) ?? context.title ?? "Meeting notes",
            summary: clean(g.summary) ?? "",
            keyPoints: cleanList(g.keyPoints),
            decisions: cleanList(g.decisions),
            actionItems: actions,
            events: events,
            emailDrafts: emails,
            openQuestions: cleanList(g.openQuestions),
            enhancedNotes: context.hasUserNotes ? clean(g.enhancedNotes) : nil,
            meetingStart: context.start,
            timeZoneIdentifier: context.timeZone.identifier,
            generatedBy: generatedBy
        )
    }

    private static func cleanOwner(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t.lowercased() {
        case "", "unknown", "n/a", "none", "unclear", "unassigned", "tbd": return nil
        case "me", "i", "myself", "user": return "Me"
        default: return t
        }
    }
}

/// Strict `YYYY-MM-DD` / `YYYY-MM-DDTHH:mm` handling, independent of time zone.
enum ISODate {
    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// Returns the input (trimmed) if it's a real calendar date, else nil.
    static func validDate(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              DateComponents(calendar: calendar, year: y, month: m, day: d).isValidDate(in: calendar)
        else { return nil }
        return s
    }

    /// Accepts a date, or a date + `THH:mm` (a trailing `:ss` is trimmed off).
    static func validStart(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = s.firstIndex(of: "T") else { return validDate(s) }
        let date = String(s[..<t])
        let time = s[s.index(after: t)...].split(separator: ":")
        guard validDate(date) != nil, time.count >= 2, time[0].count == 2, time[1].count >= 2,
              let h = Int(time[0]), let m = Int(time[1].prefix(2)), (0 ..< 24).contains(h), (0 ..< 60).contains(m)
        else { return nil }
        return String(format: "%@T%02d:%02d", date, h, m)
    }

    /// Days since a fixed epoch, so two `YYYY-MM-DD` strings compare correctly.
    static func dayNumber(of date: String) -> Int {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3,
              let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
        else { return Int.min }
        return Int(d.timeIntervalSinceReferenceDate / 86400)
    }

    /// The same numbering for a real instant, seen in `calendar`'s time zone.
    static func dayNumber(of date: Date, calendar tz: Calendar) -> Int {
        let c = tz.dateComponents([.year, .month, .day], from: date)
        return dayNumber(of: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }
}
