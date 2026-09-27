import AVFAudio
import Foundation
import MuesliAudio
import MuesliCore
import Testing
@testable import MuesliTranscribe

@Suite("Whisper: finding Python and the model")
struct WhisperDiscoveryTests {
    @Test("an explicit MUESLI_PYTHON comes first, the rest follow, and nothing is listed twice")
    func order() {
        let existing: Set<String> = ["/custom/py", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Users/me/venv/bin/python3"]
        let found = WhisperTranscriber.candidateInterpreters(
            environment: ["MUESLI_PYTHON": "/custom/py", "PATH": "/Users/me/venv/bin:/opt/homebrew/bin:/usr/bin"],
            fileExists: { existing.contains($0) })
        #expect(found == ["/custom/py", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Users/me/venv/bin/python3"])
    }

    @Test("the system python is tried only when developer tools exist, to avoid the install dialog")
    func systemPython() {
        let without = WhisperTranscriber.candidateInterpreters(environment: ["PATH": "/usr/bin"], fileExists: { $0 == "/usr/bin/python3" })
        #expect(without.isEmpty)
        let with = WhisperTranscriber.candidateInterpreters(
            environment: ["PATH": "/usr/bin"],
            fileExists: { ["/usr/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3"].contains($0) })
        #expect(with == ["/usr/bin/python3"])
    }

    @Test("picks the first interpreter that actually has mlx-whisper")
    func locate() {
        let picked = WhisperTranscriber.locate(candidates: ["/a", "/b", "/c"], hasMLXWhisper: { $0 != "/a" })
        #expect(picked == "/b")
        #expect(WhisperTranscriber.locate(candidates: ["/a"], hasMLXWhisper: { _ in false }) == nil)
    }

    @Test("an interpreter that lacks mlx-whisper, or doesn't exist, is not chosen")
    func realProbe() {
        #expect(!WhisperTranscriber.probe(python: "/nonexistent/python"))
        #expect(!WhisperTranscriber.probe(python: "/usr/bin/false"))
    }

    @Test("the not-found error says how to fix it")
    func errorMessage() {
        let text = WhisperTranscriber.Failure.pythonNotFound(tried: ["/x/python3"]).localizedDescription
        #expect(text.contains("pip install mlx-whisper") && text.contains("MUESLI_PYTHON") && text.contains("/x/python3"))
    }

    @Test("finds a cached Hugging Face model, honoring HF_HUB_CACHE and HF_HOME")
    func modelCache() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "muesli-hf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appending(path: "hub/models--acme--whisper-x/snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        #expect(WhisperTranscriber.isModelCached("acme/whisper-x", environment: ["HF_HOME": root.path]))
        #expect(WhisperTranscriber.isModelCached("acme/whisper-x", environment: ["HF_HUB_CACHE": root.appending(path: "hub").path]))
        #expect(!WhisperTranscriber.isModelCached("acme/other", environment: ["HF_HOME": root.path]))
        #expect(WhisperTranscriber.isModelCached(snapshot.path)) // a local folder
        #expect(!WhisperTranscriber.isModelCached("/no/such/folder"))
    }
}

@Suite("Whisper: reading its output")
struct WhisperOutputTests {
    private let line = #"@@MUESLI@@{"language":"ar","regions":[{"index":0,"segments":[{"start":0.5,"end":2.0,"text":" مرحبا بكم","no_speech_prob":0.01,"avg_logprob":-0.25,"compression_ratio":1.2},{"start":2.0,"end":3.0,"text":" Thank you.","no_speech_prob":0.7,"avg_logprob":-1.4,"compression_ratio":0.8}]},{"index":1,"segments":[{"start":0.0,"end":1.5,"text":" the budget is ready","no_speech_prob":0.02,"avg_logprob":-0.1,"compression_ratio":1.5}]}]}"#

    @Test("finds the result line among library chatter")
    func decodesAmongNoise() throws {
        let data = Data("Fetching 4 files\nsome warning\n\(line)\n".utf8)
        let out = try WhisperTranscriber.decode(data)
        #expect(out.language == "ar")
        #expect(out.regions.count == 2 && out.regions[0].segments.count == 2)
        #expect(out.regions[0].segments[0].avgLogprob == -0.25)
    }

    @Test("missing or malformed output is a clear error, not a crash")
    func badOutput() {
        #expect(throws: WhisperTranscriber.Failure.self) { try WhisperTranscriber.decode(Data("nothing useful".utf8)) }
        #expect(throws: WhisperTranscriber.Failure.self) { try WhisperTranscriber.decode(Data("@@MUESLI@@{not json".utf8)) }
        #expect(throws: WhisperTranscriber.Failure.self) { try WhisperTranscriber.decode(Data()) }
    }

    @Test("segment times are placed on the session clock, and hallucinations are dropped")
    func mapping() throws {
        let out = try WhisperTranscriber.decode(Data(line.utf8))
        let regions = [SpeechRegion(start: 10, end: 20), SpeechRegion(start: 30, end: 40)]
        let segments = WhisperTranscriber.segments(from: out, regions: regions, speaker: .them, startOffset: 100)

        #expect(segments.map(\.text) == ["مرحبا بكم", "the budget is ready"]) // "Thank you." at 0.7 no-speech dropped
        #expect(segments[0].start == 110.5 && segments[0].end == 112.0) // 100 offset + 10 region + 0.5
        #expect(segments[1].start == 130.0 && segments[1].end == 131.5)
        #expect(segments.allSatisfy { $0.speaker == .them })
        let confidence = try #require(segments[0].confidence)
        #expect(abs(confidence - exp(-0.25)) < 1e-9)
    }

    @Test("a region index the gate never produced is ignored")
    func strayRegion() throws {
        let out = try WhisperTranscriber.decode(Data(line.utf8))
        let one = WhisperTranscriber.segments(from: out, regions: [SpeechRegion(start: 0, end: 5)], speaker: .me, startOffset: 0)
        #expect(one.map(\.text) == ["مرحبا بكم"])
    }
}

@Suite("Whisper: the helper script")
struct WhisperHelperTests {
    @Test("keeps the safeguards that testing showed are essential")
    func safeguards() {
        let source = WhisperTranscriber.helperSource
        // Whisper's default conditioning looped on phone-quality audio (+101 words).
        #expect(source.contains("condition_on_previous_text=False"))
        // Library output must never corrupt the result line.
        #expect(source.contains("sys.stdout = sys.stderr"))
        #expect(source.contains("@@MUESLI@@"))
    }

    @Test("takes its inputs from stdin, so nothing user-controlled is ever part of the code")
    func noInterpolation() {
        let source = WhisperTranscriber.helperSource
        #expect(source.contains("json.load(sys.stdin)"))
        #expect(!source.contains("os.system") && !source.contains("subprocess") && !source.contains("eval("))
    }

    @Test("the marker matches what the Swift side looks for")
    func marker() {
        #expect(WhisperTranscriber.helperSource.contains(WhisperTranscriber.resultMarker))
    }
}

/// Runs the real model. Needs mlx-whisper and the model on this Mac, so it's off
/// unless you ask: `MUESLI_TEST_WHISPER=1 scripts/test.sh`.
@Suite("Whisper: end to end", .enabled(if: ProcessInfo.processInfo.environment["MUESLI_TEST_WHISPER"] == "1"))
struct WhisperLiveTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/launch-update.m4a")

    @Test("transcribes a spoken fixture and ignores silence around it")
    func fixtureWithSilence() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "muesli-whisper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try StreamRecorder(url: folder.appending(path: "s.wav"))

        let silence = AVAudioPCMBuffer(pcmFormat: StreamRecorder.format, frameCapacity: 16_000 * 20)!
        silence.frameLength = silence.frameCapacity // zeros
        try recorder.write(AudioChunk(buffer: silence))
        for await chunk in try AudioFileSource.chunks(url: Self.fixture) { try recorder.write(chunk) }
        try recorder.write(AudioChunk(buffer: silence))
        recorder.finish()

        let result = try await WhisperTranscriber().transcribe(wav: recorder.url, speaker: .them, startOffset: 0)
        let text = result.segments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("budget"), "got: \(text)")
        #expect(text.contains("monday"), "got: \(text)")
        #expect(result.language == "en")
        #expect(result.segments.allSatisfy { $0.start >= 19 }, "speech starts after 20 s of silence: \(result.segments.map(\.start))")
    }
}
