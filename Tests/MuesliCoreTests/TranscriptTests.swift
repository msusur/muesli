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

    @Test("markdown headings show the time of day in the meeting's time zone, and plain text doesn't")
    func clockTimes() {
        // 2026-10-28 11:47:30 UTC; London is on GMT then.
        var t = Transcript(startedAt: Date(timeIntervalSince1970: 1_792_928_850), locale: "en-GB", timeZoneIdentifier: "Europe/London")
        t.append(seg(.them, 31, 40, "where the ownership lies"))
        t.append(seg(.me, 7_300, 7_305, "Yeah."))
        let md = t.markdown()
        #expect(md.contains("**Them** `00:31` (11:48am)  \nwhere the ownership lies"))
        #expect(md.contains("**Me** `2:01:40` (1:49pm)  \nYeah."))
        #expect(!t.plainText().contains("am)"))

        let tokyo = Transcript(startedAt: t.startedAt, locale: "ja-JP", timeZoneIdentifier: "Asia/Tokyo")
        #expect(tokyo.clockTime(t.startedAt) == "8:47pm")
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

    @Test("annotations go under the turn they're on, notes from before anything was said come first")
    func annotationsInMarkdown() {
        let t = Transcript(
            startedAt: Date(timeIntervalSince1970: 1_792_928_850), locale: "en-GB", timeZoneIdentifier: "Europe/London",
            segments: [seg(.them, 31, 33, "Budget is fixed"), seg(.them, 34, 36, "for Q1"), seg(.me, 40, 42, "Okay")],
            annotations: [.init(at: 40, text: "Agree?"), .init(at: 34, text: "Check with finance\nby Friday"), .init(at: 0, text: "Prep")])
        #expect(t.annotations.map(\.text) == ["Prep", "Check with finance\nby Friday", "Agree?"])
        let body = t.markdownBody()
        #expect(body == """
            > **Note** `00:00` (11:47am)  
            > Prep

            **Them** `00:31` (11:48am)  
            Budget is fixed for Q1

            > **Note** `00:34` (11:48am)  
            > Check with finance  
            > by Friday

            **Me** `00:40` (11:48am)  
            Okay

            > **Note** `00:40` (11:48am)  
            > Agree?


            """)
        #expect(t.markdown().hasSuffix(body))
        #expect(!t.plainText().contains("Note"))
    }

    @Test("a filtered transcript keeps only the chosen lines and annotations")
    func filtered() {
        let t = Transcript(locale: "en-GB", segments: [seg(.me, 0, 1, "a"), seg(.them, 5, 6, "b")],
                           annotations: [.init(at: 0, text: "x"), .init(at: 5, text: "y")])
        let part = t.filtered(segments: { $0.start >= 5 }, annotations: { $0.at >= 5 })
        #expect(part.segments.map(\.text) == ["b"])
        #expect(part.annotations.map(\.text) == ["y"])
        #expect(part.startedAt == t.startedAt)
    }

    @Test("annotations round-trip through JSON, and files without them still load")
    func annotationsCodable() throws {
        let t = Transcript(startedAt: Date(timeIntervalSince1970: 1_700_000_000), locale: "en-GB", segments: [seg(.me, 0, 1, "Hi")], annotations: [.init(at: 0, text: "note")])
        #expect(try Transcript.load(jsonData: t.jsonData()) == t)

        let plain = Transcript(locale: "en-GB", segments: [seg(.me, 0, 1, "Hi")])
        let json = String(decoding: try plain.jsonData(), as: UTF8.self)
        #expect(!json.contains("annotations"))
        #expect(try Transcript.load(jsonData: Data(json.utf8)).annotations.isEmpty)
    }
}
