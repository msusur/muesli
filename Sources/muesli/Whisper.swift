import AVFAudio
import Foundation
import MuesliAudio
import MuesliCore
import MuesliTranscribe

/// Which speech engine turns audio into text.
enum Engine: Equatable {
    /// Apple's on-device recognizer: live, fast, 25 languages.
    case apple
    /// Whisper after the recording stops: 99 languages, no live text.
    case whisper
    /// Live text from Apple while recording, then Whisper replaces it as the final transcript.
    case appleThenWhisper

    init(_ options: Options) throws {
        switch options.value("--engine")?.lowercased() {
        case nil, "apple": self = .apple
        case "whisper": self = .whisper
        case "apple+whisper": self = .appleThenWhisper
        case let other?: throw UsageError("unknown engine “\(other)”. Choose apple, whisper or apple+whisper")
        }
    }

    var usesApple: Bool { self != .whisper }
    var usesWhisper: Bool { self != .apple }
}

/// `--whisper-model`, `--whisper-language`, or a language taken from `--locale`.
/// With none of them the language is detected, so a meeting in an unexpected
/// language isn't silently forced into English.
func whisperConfiguration(_ options: Options) -> WhisperConfiguration {
    var language: String?
    if let raw = options.value("--whisper-language") {
        language = raw.lowercased() == "auto" ? nil : raw.lowercased()
    } else if let locale = options.value("--locale") {
        language = Locale(identifier: locale).language.languageCode?.identifier
    }
    return WhisperConfiguration(model: options.value("--whisper-model") ?? WhisperConfiguration.defaultModel, language: language)
}

/// Checks Whisper can run, before a meeting is recorded rather than after.
func preflightWhisper(_ configuration: WhisperConfiguration) throws {
    _ = try WhisperTranscriber(configuration: configuration).resolvePython()
    if !WhisperTranscriber.isModelCached(configuration.model) {
        let size = configuration.model == WhisperConfiguration.defaultModel ? "about 3 GB" : "a few GB"
        fputs("Note: the Whisper model “\(configuration.model)” isn't downloaded yet. The first run will fetch it (\(size), one time).\n", stderr)
    }
}

/// One recorded stream to transcribe.
struct RecordedStream {
    var speaker: Speaker
    var wav: URL
    /// Seconds between the session start and this stream's first sample.
    var offset: TimeInterval
}

/// Runs Whisper over each stream and merges the results into one transcript.
func runWhisperPass(
    _ streams: [RecordedStream], configuration: WhisperConfiguration, startedAt: Date
) async throws -> Transcript {
    let transcriber = WhisperTranscriber(configuration: configuration)
    var transcript = Transcript(startedAt: startedAt, locale: configuration.language ?? "und")
    var detected: String?

    for stream in streams {
        fputs("Whisper (\(stream.speaker.label)): finding speech…\n", stderr)
        let result = try await transcriber.transcribe(wav: stream.wav, speaker: stream.speaker, startOffset: stream.offset) { done, total in
            fputs("\r  \(done)/\(total) stretches of speech", stderr)
        }
        if result.regionCount > 0 { fputs("\n", stderr) }
        if result.regionCount == 0 { fputs("  no speech found\n", stderr) }
        for segment in result.segments { transcript.append(segment) }
        detected = detected ?? result.language
    }
    if let detected { transcript.locale = detected }
    return transcript
}

/// Converts any audio file the system can read to a 16 kHz mono WAV.
func convertToWAV(_ source: URL, to destination: URL) async throws {
    let recorder = try StreamRecorder(url: destination)
    for await chunk in try AudioFileSource.chunks(url: source) { try recorder.write(chunk) }
    recorder.finish()
}

func printSegments(_ transcript: Transcript) {
    for segment in transcript.segments {
        print("[\(Transcript.timestamp(segment.start))] \(segment.speaker.label): \(segment.text)")
    }
}
