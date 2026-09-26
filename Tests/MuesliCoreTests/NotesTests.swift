import Foundation
import Testing
@testable import MuesliCore

private let london = TimeZone(identifier: "Europe/London")!

/// Friday 25 Sep 2026, 14:30 in London.
private func meetingStart() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = london
    return cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 14, minute: 30))!
}

private func context(notes: String? = nil, title: String? = nil) -> MeetingContext {
    MeetingContext(title: title, start: meetingStart(), timeZone: london, userNotes: notes)
}

// MARK: - Schema

@Suite("Notes schema")
struct SchemaTests {
    @Test("escapes strings")
    func escaping() {
        #expect(JSONValue.string("a\"b\\c\nd\te\u{01}").serialized() == "\"a\\\"b\\\\c\\nd\\te\\u0001\"")
    }

    @Test("keeps object keys in insertion order")
    func order() {
        let v = JSONValue.object(["z": .int(1), "a": .bool(true), "m": .array([.string("x")])])
        #expect(v.serialized() == #"{"z":1,"a":true,"m":["x"]}"#)
    }

    @Test("every property is required, in declaration order, with no extras allowed")
    func strictShape() throws {
        let json = NotesSchema.jsonSchema().serialized()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["additionalProperties"] as? Bool == false)
        let required = try #require(object["required"] as? [String])
        #expect(required == ["title", "summary", "keyPoints", "decisions", "actionItems", "events", "emailDrafts", "openQuestions", "enhancedNotes"])

        // Declaration order survives serialization (summary before the fields derived from it).
        let titleAt = try #require(json.range(of: "\"title\":{"))
        let summaryAt = try #require(json.range(of: "\"summary\":{"))
        let actionsAt = try #require(json.range(of: "\"actionItems\":{"))
        #expect(titleAt.lowerBound < summaryAt.lowerBound && summaryAt.lowerBound < actionsAt.lowerBound)

        // Nested objects are strict too.
        let props = try #require(object["properties"] as? [String: Any])
        let items = try #require((props["actionItems"] as? [String: Any])?["items"] as? [String: Any])
        #expect(items["additionalProperties"] as? Bool == false)
        #expect((items["required"] as? [String]) == ["title", "owner", "dueDate", "dueText", "context"])
    }

    @Test("schema property names match what GeneratedNotes decodes")
    func matchesWireType() throws {
        let json = NotesSchema.jsonSchema().serialized()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let schemaKeys = Set((object["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
        let encoded = try JSONEncoder().encode(GeneratedNotes())
        let wireKeys = Set((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?.keys.map { $0 } ?? [])
        #expect(schemaKeys == wireKeys)
    }
}

// MARK: - Parsing & normalization

@Suite("Generated notes parsing")
struct ParsingTests {
    @Test("accepts JSON wrapped in a code fence and commentary")
    func fenced() throws {
        let text = "Here you go:\n```json\n{\"title\":\"T\",\"summary\":\"S\"}\n```\nHope that helps."
        let notes = try GeneratedNotes.parse(text)
        #expect(notes.title == "T" && notes.summary == "S")
        #expect(notes.actionItems.isEmpty)
    }

    @Test("forgives common type slips from local models")
    func lenient() throws {
        let text = """
        {"title":"T","keyPoints":"just one point",
         "events":[{"title":"Call","start":"2026-10-02T15:00","durationMinutes":"30","attendees":"Bob"}],
         "emailDrafts":[{"to":"Sarah","subject":"Hi","body":"Body"}]}
        """
        let notes = try GeneratedNotes.parse(text)
        #expect(notes.keyPoints == ["just one point"])
        #expect(notes.events.first?.durationMinutes == 30)
        #expect(notes.events.first?.attendees == ["Bob"])
        #expect(notes.emailDrafts.first?.to == ["Sarah"])
    }

    @Test("rejects text with no JSON object")
    func garbage() {
        #expect(throws: SummarizeError.self) { try GeneratedNotes.parse("I can't do that.") }
    }
}

@Suite("Normalization")
struct NormalizationTests {
    private func normalize(_ g: GeneratedNotes, notes: String? = nil) -> MeetingNotes {
        MeetingNotes(normalizing: g, context: context(notes: notes), generatedBy: "test")
    }

    @Test("keeps a valid future due date and the spoken words")
    func validDue() {
        let n = normalize(.init(actionItems: [.init(title: "Send budget", owner: "me", dueDate: "2026-09-28", dueText: "by Monday")]))
        #expect(n.actionItems[0].dueDate == "2026-09-28")
        #expect(n.actionItems[0].dueText == "by Monday")
        #expect(n.actionItems[0].owner == "Me")
    }

    @Test("drops impossible and past dates but keeps the words")
    func badDates() {
        let n = normalize(.init(actionItems: [
            .init(title: "A", dueDate: "2026-02-31", dueText: "soon"),
            .init(title: "B", dueDate: "2026-09-20", dueText: "last Sunday"), // before the meeting
            .init(title: "C", dueDate: "next week", dueText: "next week"),
            .init(title: "D", dueDate: "2026-09-25", dueText: "today"), // same day is fine
        ]))
        #expect(n.actionItems.map(\.dueDate) == [nil, nil, nil, "2026-09-25"])
        #expect(n.actionItems[0].dueText == "soon")
    }

    @Test("cleans owners, dedupes and drops blanks")
    func cleaning() {
        let n = normalize(.init(
            keyPoints: ["Same", "same ", "", "Other"],
            actionItems: [
                .init(title: "Do it", owner: "Unknown"),
                .init(title: "do it", owner: "Sarah"),
                .init(title: "  ", owner: "Sarah"),
                .init(title: "Ping Bob", owner: "Sarah"),
            ]
        ))
        #expect(n.keyPoints == ["Same", "Other"])
        #expect(n.actionItems.map(\.title) == ["Do it", "Ping Bob"])
        #expect(n.actionItems[0].owner == nil)
        #expect(n.actionItems[1].owner == "Sarah")
    }

    @Test("validates event starts")
    func events() {
        let n = normalize(.init(events: [
            .init(title: "With time", start: "2026-10-02T15:00:00", durationMinutes: 30, attendees: ["Bob", "bob", "Me"]),
            .init(title: "Day only", start: "2026-10-03"),
            .init(title: "Bad time", start: "2026-10-03T25:00"),
            .init(title: "Past", start: "2026-09-01T09:00"),
            .init(title: "", start: "2026-10-04"),
        ]))
        #expect(n.events.map(\.title) == ["With time", "Day only", "Bad time", "Past"])
        #expect(n.events.map(\.start) == ["2026-10-02T15:00", "2026-10-03", nil, nil])
        #expect(n.events[0].hasTime && !n.events[1].hasTime)
        #expect(n.events[0].durationMinutes == 30 && n.events[1].durationMinutes == nil)
        #expect(n.events[0].attendees == ["Bob"])
    }

    @Test("enhanced notes are kept only when the user wrote notes")
    func enhanced() {
        let g = GeneratedNotes(enhancedNotes: "## Expanded")
        #expect(normalize(g, notes: "- budget").enhancedNotes == "## Expanded")
        #expect(normalize(g, notes: "   \n").enhancedNotes == nil)
        #expect(normalize(g).enhancedNotes == nil)
    }

    @Test("falls back to the supplied title")
    func title() {
        let n = MeetingNotes(normalizing: GeneratedNotes(), context: context(title: "Vendor call"), generatedBy: "t")
        #expect(n.title == "Vendor call")
    }

    @Test("markdown includes checklist items, owners and due dates")
    func markdown() {
        let n = normalize(.init(
            title: "Launch sync", summary: "Moved the launch.",
            actionItems: [.init(title: "Send budget", owner: "Me", dueDate: "2026-09-28", dueText: "by Monday", context: "Finance needs it.")],
            emailDrafts: [.init(to: ["Board"], subject: "Summary", body: "Hi all")]
        ))
        let md = n.markdown()
        #expect(md.hasPrefix("# Launch sync"))
        #expect(md.contains("- [ ] Send budget — Me · due 2026-09-28 (by Monday)"))
        #expect(md.contains("  - Finance needs it."))
        #expect(md.contains("### Summary\nTo: Board"))
    }
}

// MARK: - Prompts

@Suite("Prompts")
struct PromptTests {
    @Test("header gives the meeting day, time zone and a 14-day calendar")
    func header() {
        let h = Prompts.header(context(title: "Vendor call"))
        #expect(h.contains("Meeting: Vendor call"))
        #expect(h.contains("Started: Friday 2026-09-25 14:30 (Europe/London)"))
        #expect(h.contains("Fri 2026-09-25 (meeting day), Sat 2026-09-26, Sun 2026-09-27, Mon 2026-09-28"))
        #expect(h.contains("Thu 2026-10-08"))
        #expect(!h.contains("Fri 2026-10-09"))
    }

    @Test("user notes appear only when provided")
    func notes() {
        let with = Prompts.single(transcript: "[00:00] Me: hi", context: context(notes: "- budget"))
        #expect(with.contains("<user_notes>\n- budget\n</user_notes>"))
        #expect(with.contains("<transcript>\n[00:00] Me: hi\n</transcript>"))
        #expect(!Prompts.single(transcript: "x", context: context()).contains("user_notes"))
    }

    @Test("merge prompt carries the parts and only sees user notes on the final round")
    func merge() {
        let parts = [GeneratedNotes(title: "A", enhancedNotes: "ignored"), GeneratedNotes(title: "B")]
        let final = Prompts.merge(parts, context: context(notes: "- mine"), isFinal: true)
        #expect(final.contains("Part 1: ") && final.contains("Part 2: "))
        #expect(final.contains("<user_notes>"))
        #expect(!final.contains("ignored"))
        let mid = Prompts.merge(parts, context: context(notes: "- mine"), isFinal: false)
        #expect(!mid.contains("<user_notes>"))
        #expect(mid.contains("Leave enhancedNotes empty."))
    }
}

// MARK: - Chunking

@Suite("Chunker")
struct ChunkerTests {
    @Test("packs whole lines under the limit and loses nothing")
    func packs() {
        let lines = (1 ... 40).map { "line \($0) " + String(repeating: "x", count: 30) }
        let chunks = TranscriptChunker.chunks(lines: lines, maxCharacters: 300)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 300 })
        #expect(chunks.joined(separator: "\n") == lines.joined(separator: "\n"))
    }

    @Test("splits an oversized line at word boundaries without dropping words")
    func longLine() {
        let words = (1 ... 200).map { "word\($0)" }
        let chunks = TranscriptChunker.chunks(lines: [words.joined(separator: " ")], maxCharacters: 250)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 250 })
        #expect(chunks.joined(separator: " ").split(separator: " ").map(String.init) == words)
    }
}

// MARK: - Summarizer

/// Records every request and answers deterministically.
final class FakeGenerator: NotesGenerator, @unchecked Sendable {
    let displayName = "fake:model"
    let budget: Int
    private let lock = NSLock()
    private var _users: [String] = []
    var users: [String] { lock.withLock { _users } }

    init(budget: Int) { self.budget = budget }
    var transcriptCharacterBudget: Int { get async { budget } }

    func generate(system: String, user: String) async throws -> GenerationResult {
        lock.withLock { _users.append(user) }
        var notes = GeneratedNotes(title: "T", summary: "S")
        if let part = user.range(of: #"part (\d+) of"#, options: .regularExpression) {
            notes.actionItems = [.init(title: "Task from \(user[part])")]
        }
        if user.contains("<user_notes>") { notes.enhancedNotes = "## Enhanced" }
        return GenerationResult(notes: notes, usage: TokenUsage(inputTokens: 100, outputTokens: 10))
    }
}

private func longTranscript(turns: Int) -> Transcript {
    var t = Transcript(startedAt: meetingStart(), locale: "en-US")
    for i in 0 ..< turns {
        t.append(TranscriptSegment(
            speaker: i % 2 == 0 ? .me : .them, start: Double(i) * 10, end: Double(i) * 10 + 5,
            text: "This is sentence number \(i) of the meeting and it has some words in it."
        ))
    }
    return t
}

@Suite("MeetingSummarizer")
struct SummarizerTests {
    @Test("short meeting takes a single request")
    func single() async throws {
        let gen = FakeGenerator(budget: 100_000)
        let result = try await MeetingSummarizer(generator: gen).summarize(longTranscript(turns: 6), context: context())
        #expect(result.requests == 1)
        #expect(gen.users.count == 1)
        #expect(result.usage == TokenUsage(inputTokens: 100, outputTokens: 10))
        #expect(result.notes.generatedBy == "fake:model")
        #expect(result.notes.enhancedNotes == nil)
    }

    @Test("long meeting is split into parts, then merged once")
    func mapReduce() async throws {
        let gen = FakeGenerator(budget: 1500)
        let transcript = longTranscript(turns: 60)
        let result = try await MeetingSummarizer(generator: gen).summarize(transcript, context: context(notes: "- my notes"))

        let parts = gen.users.filter { $0.contains("This is part ") }
        let merges = gen.users.filter { $0.contains("<parts>") }
        #expect(parts.count >= 3)
        #expect(merges.count == 1)
        #expect(result.requests == parts.count + 1)
        #expect(result.usage.inputTokens == 100 * result.requests)

        // The last request is the merge, and it saw every part's notes and the user's notes.
        #expect(gen.users.last?.contains("<parts>") == true)
        #expect(merges[0].contains("<user_notes>"))
        for i in 1 ... parts.count { #expect(merges[0].contains("Task from part \(i) of")) }
        // Parts themselves never carry the notes.
        #expect(parts.allSatisfy { !$0.contains("<user_notes>") })

        // Every transcript line reached exactly one part.
        let seen = parts.joined().components(separatedBy: "sentence number ").dropFirst()
            .compactMap { Int($0.prefix { $0.isNumber }) }
        #expect(seen.sorted() == Array(0 ..< 60))
        #expect(result.notes.enhancedNotes == "## Enhanced")
    }

    @Test("merging terminates even when the window is tiny")
    func tinyWindow() async throws {
        let gen = FakeGenerator(budget: 1_000)
        let result = try await MeetingSummarizer(generator: gen).summarize(longTranscript(turns: 60), context: context())
        #expect(result.requests == gen.users.count)
        #expect(gen.users.last?.contains("<parts>") == true)
    }

    @Test("a context window too small to be useful is refused up front")
    func tooSmall() async {
        let gen = FakeGenerator(budget: 200)
        await #expect(throws: SummarizeError.contextTooSmall(characters: 200)) {
            try await MeetingSummarizer(generator: gen).summarize(longTranscript(turns: 10), context: context())
        }
        #expect(gen.users.isEmpty)
    }

    @Test("empty transcript is an error, not a wasted request")
    func empty() async {
        let gen = FakeGenerator(budget: 1000)
        await #expect(throws: SummarizeError.emptyTranscript) {
            try await MeetingSummarizer(generator: gen).summarize(Transcript(locale: "en-US"), context: context())
        }
        #expect(gen.users.isEmpty)
    }
}
