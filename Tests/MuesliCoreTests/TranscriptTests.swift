import Foundation
import Testing
@testable import MuesliCore

@Suite("Transcript")
struct TranscriptTests {
    private func seg(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    @Test("interleaves two streams by start time")
    func interleaves() {
        var t = Transcript(locale: "en-US")
        t.append(seg(.them, 5, 7, "second"))
        t.append(seg(.me, 1, 3, "first"))
        t.append(seg(.me, 9, 10, "third"))
        #expect(t.segments.map(\.text) == ["first", "second", "third"])
    }

    @Test("drops empty and whitespace-only segments")
    func dropsEmpty() {
        var t = Transcript(locale: "en-US")
        t.append(seg(.me, 0, 1, "   \n"))
        t.append(seg(.me, 1, 2, "  hello  "))
        #expect(t.segments.count == 1)
        #expect(t.segments[0].text == "hello")
    }

    @Test("merges same-speaker segments within the gap, splits beyond it")
    func turnMerging() {
        var t = Transcript(locale: "en-US")
        t.append(seg(.me, 0, 2, "Hello there."))
        t.append(seg(.me, 3, 5, "How are you?"))
        t.append(seg(.them, 6, 8, "Good."))
        t.append(seg(.them, 20, 22, "Anyway."))
        let turns = t.turns(maxGap: 4)
        #expect(turns.count == 3)
        #expect(turns[0].text == "Hello there. How are you?")
        #expect(turns[0].end == 5)
        #expect(turns[2].text == "Anyway.")
    }

    @Test("does not merge across a speaker change")
    func speakerChange() {
        var t = Transcript(locale: "en-US")
        t.append(seg(.me, 0, 1, "a"))
        t.append(seg(.them, 1.5, 2, "b"))
        t.append(seg(.me, 2.5, 3, "c"))
        #expect(t.turns().map(\.speaker) == [.me, .them, .me])
    }

    @Test("timestamp formatting")
    func timestamps() {
        #expect(Transcript.timestamp(0) == "00:00")
        #expect(Transcript.timestamp(75.9) == "01:15")
        #expect(Transcript.timestamp(3725) == "1:02:05")
        #expect(Transcript.timestamp(-3) == "00:00")
    }

    @Test("plain text is one line per turn")
    func plainText() {
        var t = Transcript(locale: "en-US")
        t.append(seg(.me, 0, 1, "Hi"))
        t.append(seg(.them, 2, 3, "Hello"))
        #expect(t.plainText() == "[00:00] Me: Hi\n[00:02] Them: Hello")
    }

    @Test("round-trips through JSON")
    func codable() throws {
        var t = Transcript(startedAt: Date(timeIntervalSince1970: 1_700_000_000), locale: "en-GB")
        t.append(seg(.me, 0, 1, "Hi"))
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(back == t)
    }
}
