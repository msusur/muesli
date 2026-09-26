import AVFAudio
import Foundation
import MuesliAudio
import MuesliCore
@testable import MuesliTranscribe
import Speech
import Testing

/// Runs the real on-device recognizer, so it needs the en-US speech model
/// (macOS downloads it on first use) and fails with a clear message without it.
@Suite("File transcription")
struct FileTranscriptionTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/launch-update.m4a")

    @Test("transcribes a spoken fixture end to end")
    func transcribesFixture() async throws {
        let locale: Locale
        do {
            locale = try await StreamTranscriber.prepare(locale: Locale(identifier: "en-US"))
        } catch {
            Issue.record("Needs the en-US speech model (downloaded on first use, so the first run needs network): \(error.localizedDescription)")
            return
        }

        let transcriber = StreamTranscriber(speaker: .them, locale: locale)
        var transcript = Transcript(locale: locale.identifier)
        for try await segment in transcriber.transcribe(try AudioFileSource.chunks(url: Self.fixture)) {
            transcript.append(segment)
        }

        let text = transcript.plainText().lowercased()
        #expect(text.contains("launch"), "got: \(text)")
        #expect(text.contains("budget"), "got: \(text)")
        #expect(text.contains("monday"), "got: \(text)")
        #expect(transcript.segments.allSatisfy { $0.speaker == .them })
        #expect(transcript.segments.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
        #expect(transcript.duration > 1)
    }

    @Test("segments from a later-starting stream are shifted onto the session clock")
    func offsetsAreApplied() async throws {
        guard let locale = try? await StreamTranscriber.prepare(locale: Locale(identifier: "en-US")) else {
            Issue.record("Needs the en-US speech model (downloaded on first use, so the first run needs network)")
            return
        }
        // Pretend the session began 10s before this stream's first buffer.
        let clock = HostClock.now()
        let sessionStart = clock - AVAudioTime.hostTime(forSeconds: 10)
        // File chunks carry no host time, so stamp them as if captured "now".
        let fileChunks = try AudioFileSource.chunks(url: Self.fixture)
        let (stamped, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        Task {
            for await chunk in fileChunks { continuation.yield(AudioChunk(buffer: chunk.buffer, hostTime: clock)) }
            continuation.finish()
        }
        let transcriber = StreamTranscriber(speaker: .me, locale: locale, sessionStart: sessionStart)
        var first: TranscriptSegment?
        for try await segment in transcriber.transcribe(stamped) where first == nil {
            first = segment
        }
        let start = try #require(first).start
        #expect(start >= 9.5 && start < 14, "first segment started at \(start)")
    }
}
