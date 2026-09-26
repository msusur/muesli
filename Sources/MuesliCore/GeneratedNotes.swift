import Foundation

/// What a model returns, before validation. Deliberately flat and forgiving:
/// missing fields default to empty and a few common type slips (a string where
/// an array was asked for, "30" for 30) are accepted, because local models
/// without strict constrained decoding get these wrong now and then.
public struct GeneratedNotes: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [Action]
    public var events: [Event]
    public var emailDrafts: [Email]
    public var openQuestions: [String]
    public var enhancedNotes: String

    public struct Action: Codable, Sendable, Equatable {
        public var title: String
        public var owner: String
        public var dueDate: String
        public var dueText: String
        public var context: String

        public init(title: String = "", owner: String = "", dueDate: String = "", dueText: String = "", context: String = "") {
            self.title = title
            self.owner = owner
            self.dueDate = dueDate
            self.dueText = dueText
            self.context = context
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            title = c.string(.title)
            owner = c.string(.owner)
            dueDate = c.string(.dueDate)
            dueText = c.string(.dueText)
            context = c.string(.context)
        }

        enum Keys: String, CodingKey { case title, owner, dueDate, dueText, context }
    }

    public struct Event: Codable, Sendable, Equatable {
        public var title: String
        public var start: String
        public var durationMinutes: Int
        public var attendees: [String]

        public init(title: String = "", start: String = "", durationMinutes: Int = 0, attendees: [String] = []) {
            self.title = title
            self.start = start
            self.durationMinutes = durationMinutes
            self.attendees = attendees
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            title = c.string(.title)
            start = c.string(.start)
            durationMinutes = c.int(.durationMinutes)
            attendees = c.strings(.attendees)
        }

        enum Keys: String, CodingKey { case title, start, durationMinutes, attendees }
    }

    public struct Email: Codable, Sendable, Equatable {
        public var to: [String]
        public var subject: String
        public var body: String

        public init(to: [String] = [], subject: String = "", body: String = "") {
            self.to = to
            self.subject = subject
            self.body = body
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            to = c.strings(.to)
            subject = c.string(.subject)
            body = c.string(.body)
        }

        enum Keys: String, CodingKey { case to, subject, body }
    }

    public init(
        title: String = "", summary: String = "", keyPoints: [String] = [], decisions: [String] = [],
        actionItems: [Action] = [], events: [Event] = [], emailDrafts: [Email] = [],
        openQuestions: [String] = [], enhancedNotes: String = ""
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.events = events
        self.emailDrafts = emailDrafts
        self.openQuestions = openQuestions
        self.enhancedNotes = enhancedNotes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = c.string(.title)
        summary = c.string(.summary)
        keyPoints = c.strings(.keyPoints)
        decisions = c.strings(.decisions)
        actionItems = (try? c.decodeIfPresent([Action].self, forKey: .actionItems)) ?? []
        events = (try? c.decodeIfPresent([Event].self, forKey: .events)) ?? []
        emailDrafts = (try? c.decodeIfPresent([Email].self, forKey: .emailDrafts)) ?? []
        openQuestions = c.strings(.openQuestions)
        enhancedNotes = c.string(.enhancedNotes)
    }

    enum Keys: String, CodingKey {
        case title, summary, keyPoints, decisions, actionItems, events, emailDrafts, openQuestions, enhancedNotes
    }

    /// Parses a model's text output. Tolerates a markdown code fence or
    /// commentary around the JSON object.
    public static func parse(_ text: String) throws -> GeneratedNotes {
        guard let json = extractJSONObject(from: text), let data = json.data(using: .utf8) else {
            throw SummarizeError.unparseableOutput(String(text.prefix(200)))
        }
        do {
            return try JSONDecoder().decode(GeneratedNotes.self, from: data)
        } catch {
            throw SummarizeError.unparseableOutput(String(text.prefix(200)))
        }
    }

    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start ... end])
    }
}

extension KeyedDecodingContainer {
    fileprivate func string(_ key: Key) -> String {
        ((try? decodeIfPresent(String.self, forKey: key)) ?? nil) ?? ""
    }

    fileprivate func int(_ key: Key) -> Int {
        if let v = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return v }
        if let v = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(v) }
        if let v = (try? decodeIfPresent(String.self, forKey: key)) ?? nil, let n = Int(v.trimmingCharacters(in: .whitespaces)) { return n }
        return 0
    }

    fileprivate func strings(_ key: Key) -> [String] {
        if let v = (try? decodeIfPresent([String].self, forKey: key)) ?? nil { return v }
        if let v = (try? decodeIfPresent(String.self, forKey: key)) ?? nil, !v.isEmpty { return [v] }
        return []
    }
}

public enum SummarizeError: Error, LocalizedError, Equatable {
    case emptyTranscript
    case unparseableOutput(String)
    case contextTooSmall(characters: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: "The transcript is empty, so there's nothing to summarize."
        case .unparseableOutput(let head): "The model didn't return valid notes JSON. Output began: “\(head)”"
        case .contextTooSmall(let n): "This model's context window only fits \(n) characters of transcript per request, which is too small to summarize a meeting."
        }
    }
}
