import Foundation
import Testing
import MuesliCore
import MuesliSummarize
@testable import MuesliAudio
@testable import MuesliSession

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "muesli-session-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func transcript(_ lines: [(Speaker, String)], at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> Transcript {
    var t = Transcript(startedAt: date, locale: "en_GB")
    for (i, (speaker, text)) in lines.enumerated() {
        t.append(TranscriptSegment(speaker: speaker, start: Double(i * 5), end: Double(i * 5 + 4), text: text))
    }
    return t
}

@Suite("Session folders")
struct SessionFolderTests {
    @Test("a new session is named after when it started (in UTC), so names sort by time")
    func naming() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 14, minute: 30, second: 5))!
        let folder = SessionFolder.new(in: URL(fileURLWithPath: "/tmp/x"), startedAt: date)
        #expect(folder.url.lastPathComponent == "2026-09-25-143005")
    }

    @Test("a saved transcript loads back, with markdown beside it")
    func roundTrip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SessionFolder(root.appending(path: "a"))
        let original = transcript([(.me, "Hello there"), (.them, "Hi")])
        try folder.saveTranscript(original, title: "Sync")
        #expect(try folder.loadTranscript() == original)
        #expect(FileManager.default.fileExists(atPath: folder.file("transcript.md").path))
        #expect(!folder.hasNotes)
    }

    @Test("recent lists only folders with a transcript, newest first, up to the limit")
    func recent() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2026-10-01-090000", "2026-10-03-090000", "2026-10-02-090000"] {
            try SessionFolder(root.appending(path: name)).saveTranscript(transcript([(.me, "x")]), title: nil)
        }
        try FileManager.default.createDirectory(at: root.appending(path: "2026-10-04-090000"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "stray.txt"))

        let names = SessionFolder.recent(in: root, limit: 2).map(\.url.lastPathComponent)
        #expect(names == ["2026-10-03-090000", "2026-10-02-090000"])
        #expect(SessionFolder.recent(in: root.appending(path: "missing")).isEmpty)
    }

    @Test("the display title is the first words of the transcript until there are notes")
    func displayTitle() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SessionFolder(root.appending(path: "a"))
        try folder.saveTranscript(transcript([(.me, "So the plan for the quarter is to ship the menu bar app")]), title: nil)
        #expect(folder.displayTitle() == "So the plan for the quarter…")

        try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        #expect(SessionFolder(root.appending(path: "empty")).displayTitle() == "empty")
    }

    @Test("a missing or corrupt ledger reads as empty, so actions can still be proposed")
    func ledgerFallback() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SessionFolder(root)
        #expect(folder.loadLedger().entries.isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.file(SessionFolder.ledgerFile))
        #expect(folder.loadLedger().entries.isEmpty)
    }
}

@Suite("Recording options")
struct RecordingOptionTests {
    @Test("engine names match the command line")
    func engineNames() {
        #expect(Engine.allCases.map(\.rawValue) == ["apple", "whisper", "apple+whisper"])
        #expect(Engine.apple.usesApple && !Engine.apple.usesWhisper)
        #expect(!Engine.whisper.usesApple && Engine.whisper.usesWhisper)
        #expect(Engine.appleThenWhisper.usesApple && Engine.appleThenWhisper.usesWhisper)
    }

    @Test("nothing to record is refused before anything starts")
    func nothingToRecord() async {
        var options = RecordingOptions()
        options.microphone = false
        options.systemAudio = false
        await #expect(throws: RecordingError.nothingToRecord) { try await RecordingSession(options: options).start() }
    }

    @Test("Whisper without a folder to save into is refused")
    func whisperNeedsFolder() async {
        var options = RecordingOptions()
        options.engine = .whisper
        await #expect(throws: RecordingError.whisperNeedsFolder) { try await RecordingSession(options: options).start() }
    }

    @Test("stopping a session that never started says so")
    func stopBeforeStart() async {
        await #expect(throws: RecordingError.notRecording) { try await RecordingSession(options: RecordingOptions()).stop() }
    }
}

@Suite("Silent system audio")
struct SilenceTests {
    private func process(_ id: UInt32, _ name: String, playing: Bool) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid_t(id), bundleID: nil, name: name, isProducingAudio: playing)
    }

    @Test("silence only means something if an app being captured is playing")
    func capturedAppIsPlaying() {
        let musicPlaying = [process(1, "Music", playing: true), process(2, "zoom.us", playing: false)]
        #expect(RecordingSession.capturedAppIsPlaying(scope: .everything, processes: musicPlaying))
        // Recording only Zoom while music plays elsewhere: Zoom's silence is real, not a permission problem.
        #expect(!RecordingSession.capturedAppIsPlaying(scope: .only(AppSelector(["zoom"])), processes: musicPlaying))
        #expect(!RecordingSession.capturedAppIsPlaying(scope: .excluding(AppSelector(["Music"])), processes: musicPlaying))

        let zoomPlaying = [process(1, "Music", playing: false), process(2, "zoom.us", playing: true)]
        #expect(RecordingSession.capturedAppIsPlaying(scope: .only(AppSelector(["zoom"])), processes: zoomPlaying))
        #expect(RecordingSession.capturedAppIsPlaying(scope: .excluding(AppSelector(["Music"])), processes: zoomPlaying))
        #expect(!RecordingSession.capturedAppIsPlaying(scope: .everything, processes: []))
    }
}

@Suite("Disclosure")
struct DisclosureTests {
    @Test("only text that leaves the Mac is disclosed")
    func disclosures() {
        #expect(disclosure(for: .apple, baseURL: nil) == nil)
        #expect(disclosure(for: .appleCloud, baseURL: nil) != nil)
        #expect(disclosure(for: .anthropic, baseURL: nil) != nil)
        #expect(disclosure(for: .openai, baseURL: URL(string: "http://localhost:11434/v1")) == nil)
        #expect(disclosure(for: .openai, baseURL: URL(string: "http://studio.local:8080/v1")) == nil)
        #expect(disclosure(for: .openai, baseURL: URL(string: "https://api.example.com/v1"))?.contains("api.example.com") == true)
    }
}
