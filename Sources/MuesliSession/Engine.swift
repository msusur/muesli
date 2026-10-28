import Foundation
import MuesliAudio
import MuesliCore
import MuesliTranscribe

/// Which speech engine turns audio into text.
public enum Engine: String, CaseIterable, Sendable, Codable {
    /// Apple's on-device recognizer: live, fast, 25 languages.
    case apple
    /// Whisper after the recording stops: 99 languages, no live text.
    case whisper
    /// Live text from Apple while recording, then Whisper replaces it as the final transcript.
    case appleThenWhisper = "apple+whisper"

    public var usesApple: Bool { self != .whisper }
    public var usesWhisper: Bool { self != .apple }

    public var displayName: String {
        switch self {
        case .apple: "Apple (live)"
        case .whisper: "Whisper (after you stop)"
        case .appleThenWhisper: "Apple live, then Whisper"
        }
    }
}

/// Checks Whisper can run, before a meeting is recorded rather than after.
/// Returns a note worth showing the user (a large first download), if any.
public func preflightWhisper(_ configuration: WhisperConfiguration) throws -> String? {
    _ = try WhisperTranscriber(configuration: configuration).resolvePython()
    guard !WhisperTranscriber.isModelCached(configuration.model) else { return nil }
    let size = configuration.model == WhisperConfiguration.defaultModel ? "about 3 GB" : "a few GB"
    return "the Whisper model “\(configuration.model)” isn't downloaded yet. The first run will fetch it (\(size), one time)."
}

/// One recorded stream to transcribe.
public struct RecordedStream: Sendable {
    public var speaker: Speaker
    public var wav: URL
    /// Seconds between the session start and this stream's first sample.
    public var offset: TimeInterval

    public init(speaker: Speaker, wav: URL, offset: TimeInterval) {
        self.speaker = speaker
        self.wav = wav
        self.offset = offset
    }
}

/// How far a Whisper pass has got.
public enum WhisperProgress: Sendable, Equatable {
    /// Measuring a stream's audio to find where people speak.
    case finding(Speaker)
    /// `done` of `total` stretches of speech transcribed.
    case transcribing(Speaker, done: Int, total: Int)
    /// The stream had no speech in it.
    case noSpeech(Speaker)
}

/// Runs Whisper over each stream and merges the results into one transcript.
public func runWhisperPass(
    _ streams: [RecordedStream], configuration: WhisperConfiguration, startedAt: Date,
    progress: @escaping @Sendable (WhisperProgress) -> Void = { _ in }
) async throws -> Transcript {
    let transcriber = WhisperTranscriber(configuration: configuration)
    var transcript = Transcript(startedAt: startedAt, locale: configuration.language ?? "und")
    var detected: String?

    for stream in streams {
        progress(.finding(stream.speaker))
        let speaker = stream.speaker
        let result = try await transcriber.transcribe(wav: stream.wav, speaker: speaker, startOffset: stream.offset) { done, total in
            progress(.transcribing(speaker, done: done, total: total))
        }
        if result.regionCount == 0 { progress(.noSpeech(speaker)) }
        for segment in result.segments { transcript.append(segment) }
        detected = detected ?? result.language
    }
    if let detected { transcript.locale = detected }
    return transcript
}

/// Converts any audio file the system can read to a 16 kHz mono WAV.
public func convertToWAV(_ source: URL, to destination: URL) async throws {
    let recorder = try StreamRecorder(url: destination)
    for await chunk in try AudioFileSource.chunks(url: source) { try recorder.write(chunk) }
    recorder.finish()
}
