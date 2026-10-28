import Foundation
import MuesliCore
import MuesliSession
import MuesliTranscribe

extension Engine {
    init(_ options: Options) throws {
        switch options.value("--engine")?.lowercased() {
        case nil, "apple": self = .apple
        case "whisper": self = .whisper
        case "apple+whisper": self = .appleThenWhisper
        case let other?: throw UsageError("unknown engine “\(other)”. Choose apple, whisper or apple+whisper")
        }
    }
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

/// Checks Whisper can run and mentions a large first download.
func checkWhisper(_ configuration: WhisperConfiguration) throws {
    if let note = try preflightWhisper(configuration) { fputs("Note: \(note)\n", stderr) }
}

/// Prints Whisper's progress the way the terminal has always shown it.
@Sendable func printWhisperProgress(_ progress: WhisperProgress) {
    switch progress {
    case .finding(let speaker): fputs("Whisper (\(speaker.label)): finding speech…\n", stderr)
    case .transcribing(_, let done, let total):
        fputs("\r  \(done)/\(total) stretches of speech", stderr)
        if done == total { fputs("\n", stderr) }
    case .noSpeech: fputs("  no speech found\n", stderr)
    }
}

func printSegments(_ transcript: Transcript) {
    for segment in transcript.segments {
        print("[\(Transcript.timestamp(segment.start))] \(segment.speaker.label): \(segment.text)")
    }
}
