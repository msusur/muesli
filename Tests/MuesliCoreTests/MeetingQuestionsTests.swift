import Foundation
import Testing
@testable import MuesliCore

private func transcript(_ lines: [(Speaker, TimeInterval, String)]) -> Transcript {
    var t = Transcript(startedAt: Date(timeIntervalSince1970: 1_800_000_000), locale: "en-GB", timeZoneIdentifier: "Europe/London")
    for (speaker, start, text) in lines {
        t.append(TranscriptSegment(speaker: speaker, start: start, end: start + 5, text: text))
    }
    return t
}

@Suite("Meeting questions")
struct MeetingQuestionsTests {
    private let meeting = transcript([
        (.them, 0, "Welcome everyone."),
        (.me, 30, "Thanks. Let's start with the budget."),
        (.them, 95, "We agreed to ship on Friday."),
    ])

    @Test("a short meeting fits whole, oldest first, with timestamps")
    func whole() throws {
        let excerpt = try #require(MeetingQuestions.excerpt(of: meeting, characterBudget: 10_000))
        #expect(excerpt.isWholeMeeting)
        #expect(excerpt.from == 0 && excerpt.to == 100)
        #expect(excerpt.text == """
        [00:00] Them: Welcome everyone.
        [00:30] Me: Thanks. Let's start with the budget.
        [01:35] Them: We agreed to ship on Friday.
        """)
    }

    @Test("when it doesn't fit, the newest turns are kept and the gap is admitted")
    func latest() throws {
        let excerpt = try #require(MeetingQuestions.excerpt(of: meeting, characterBudget: 95))
        #expect(!excerpt.isWholeMeeting)
        #expect(excerpt.from == 30)
        #expect(excerpt.text.hasPrefix("[00:30] Me:"))
        let prompt = MeetingQuestions.prompt(question: "When do we ship?", excerpt: excerpt, history: [])
        #expect(prompt.contains("from [00:30]; earlier parts are not included"))
        #expect(prompt.hasSuffix("Question: When do we ship?"))
    }

    @Test("a single turn too long for the budget keeps its newest words")
    func oversizedTurn() throws {
        let long = transcript([(.them, 0, String(repeating: "blah ", count: 100) + "the end")])
        let excerpt = try #require(MeetingQuestions.excerpt(of: long, characterBudget: 40))
        #expect(excerpt.text.count <= 40)
        #expect(excerpt.text.hasPrefix("…") && excerpt.text.hasSuffix("the end"))
        #expect(!excerpt.isWholeMeeting)
    }

    @Test("nothing said yet means nothing to ask about")
    func empty() {
        #expect(MeetingQuestions.excerpt(of: transcript([]), characterBudget: 1_000) == nil)
    }

    @Test("earlier exchanges go in the prompt, the newest ones when space is short")
    func history() {
        let exchanges = (1 ... 5).map { MeetingQuestions.Exchange(question: "Q\($0)?", answer: String(repeating: "a", count: 40)) }
        let kept = MeetingQuestions.recentHistory(exchanges, characterBudget: 120)
        #expect(kept.map(\.question) == ["Q4?", "Q5?"])

        let excerpt = MeetingQuestions.excerpt(of: meeting, characterBudget: 10_000)!
        let prompt = MeetingQuestions.prompt(question: "And who?", excerpt: excerpt, history: kept)
        #expect(prompt.contains("Q: Q4?\nA: "))
        #expect(prompt.contains("<transcript>\n[00:00] Them: Welcome everyone."))
    }
}
