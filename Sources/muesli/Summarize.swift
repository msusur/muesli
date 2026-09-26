import Foundation
import MuesliCore
import MuesliSummarize

/// Builds the summarizer the user asked for and checks that it can work, so a
/// missing key or unavailable model fails *before* recording starts, not after
/// an hour-long meeting.
func makeGenerator(_ options: Options) async throws -> any NotesGenerator {
    let backend: Backend
    if let name = options.value("--backend") {
        guard let chosen = Backend(rawValue: name) else {
            throw UsageError("unknown backend “\(name)”. Choose one of: \(Backend.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        backend = chosen
    } else if let automatic = Backend.automatic() {
        backend = automatic
    } else {
        let why = AppleGenerator.unavailableReason(.onDevice) ?? "it isn't available"
        throw BackendError.unavailable("""
            No summarizer chosen, and Apple's on-device model can't be used: \(why)
            Choose one with --backend: apple-cloud, anthropic or openai (see `muesli --help`).
            """)
    }

    let baseURL = try options.value("--base-url").map { raw -> URL in
        guard let url = URL(string: raw), url.scheme != nil, url.host() != nil else {
            throw UsageError("--base-url must be a full URL, e.g. http://localhost:11434/v1")
        }
        return url
    }
    let contextTokens = try options.value("--context-tokens").map { raw -> Int in
        guard let n = Int(raw), n > 0 else { throw UsageError("--context-tokens must be a positive number") }
        return n
    }

    let configuration = BackendConfiguration(
        backend: backend, model: options.value("--model"), baseURL: baseURL,
        apiKeyEnvironmentVariable: options.value("--api-key-env"), contextTokens: contextTokens,
        useFallbacks: !options.has("--no-fallback")
    )
    let generator = try configuration.makeGenerator()
    try await generator.preflight()

    if let notice = disclosure(for: backend, baseURL: baseURL) { fputs("Note: \(notice)\n", stderr) }
    return generator
}

/// Sending a transcript anywhere should never be a surprise.
private func disclosure(for backend: Backend, baseURL: URL?) -> String? {
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

/// Summarizes, prints the notes, and saves `notes.md` / `notes.json` beside the transcript.
func summarizeAndSave(
    _ transcript: Transcript, generator: any NotesGenerator, options: Options, directory: URL?
) async throws {
    let userNotes = try options.value("--notes").map { path -> String in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw UsageError("couldn't read notes file: \(path)")
        }
        return text
    }
    let context = MeetingContext(
        title: options.value("--title"), start: transcript.startedAt,
        timeZone: transcript.timeZone, userNotes: userNotes
    )

    fputs("Summarizing with \(generator.displayName)…\n", stderr)
    let result = try await MeetingSummarizer(generator: generator).summarize(transcript, context: context)

    print(result.notes.markdown())
    let usage = result.usage
    let tokens = usage.inputTokens + usage.outputTokens > 0
        ? " · \(usage.inputTokens) in / \(usage.outputTokens) out tokens" : ""
    fputs("Done: \(result.requests) request\(result.requests == 1 ? "" : "s")\(tokens)\n", stderr)

    guard let directory, !options.has("--no-save") else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try result.notes.jsonData().write(to: directory.appending(path: "notes.json"))
    try result.notes.markdown().write(to: directory.appending(path: "notes.md"), atomically: true, encoding: .utf8)
    fputs("Saved → \(directory.appending(path: "notes.md").path)\n", stderr)
    if !result.notes.actionItems.isEmpty || !result.notes.events.isEmpty || !result.notes.emailDrafts.isEmpty {
        fputs("Next: review and add them to Reminders, Calendar and Mail with\n  muesli actions \"\(directory.path)\"\n", stderr)
    }
}

struct SummarizeCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        guard let path = options.positional.first else {
            throw UsageError("summarize needs a transcript.json, or the folder that contains one")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UsageError("no such file or folder: \(path)")
        }
        let file = isDirectory.boolValue ? url.appending(path: "transcript.json") : url
        guard let data = try? Data(contentsOf: file) else { throw UsageError("couldn't read \(file.path)") }
        let transcript: Transcript
        do { transcript = try Transcript.load(jsonData: data) } catch {
            throw UsageError("\(file.lastPathComponent) isn't a muesli transcript: \(error.localizedDescription)")
        }

        let generator = try await makeGenerator(options)
        let directory = options.value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? file.deletingLastPathComponent()
        try await summarizeAndSave(transcript, generator: generator, options: options, directory: directory)
    }
}
