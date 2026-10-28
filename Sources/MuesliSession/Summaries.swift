import Foundation
import MuesliCore
import MuesliSummarize

/// Sending a transcript anywhere should never be a surprise. Returns what to tell
/// the user before it happens, or `nil` if the text stays on this Mac.
public func disclosure(for backend: Backend, baseURL: URL?) -> String? {
    switch backend {
    case .apple: return nil
    case .appleCloud: return "the transcript text will be processed on Apple's Private Cloud Compute."
    case .anthropic: return "the transcript text will be sent to Anthropic's API."
    case .openai:
        guard let host = baseURL?.host() else { return nil }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
        return local ? nil : "the transcript text will be sent to \(host)."
    }
}

/// Builds the summarizer and checks it can work, so a missing key or an
/// unavailable model fails *before* recording starts, not after the meeting.
public func makeCheckedGenerator(
    _ configuration: BackendConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment
) async throws -> any NotesGenerator {
    let generator = try configuration.makeGenerator(environment: environment)
    try await generator.preflight()
    return generator
}

/// Summarizes a transcript and saves `notes.md` / `notes.json` in `folder`, if given.
public func summarize(
    _ transcript: Transcript, generator: any NotesGenerator, title: String?, userNotes: String? = nil,
    saveTo folder: SessionFolder?
) async throws -> SummaryResult {
    let context = MeetingContext(title: title, start: transcript.startedAt, timeZone: transcript.timeZone, userNotes: userNotes)
    let result = try await MeetingSummarizer(generator: generator).summarize(transcript, context: context)
    try folder?.saveNotes(result.notes)
    return result
}

extension MeetingNotes {
    /// Whether there's anything `muesli actions` could add.
    public var hasProposals: Bool { !actionItems.isEmpty || !events.isEmpty || !emailDrafts.isEmpty }
}
