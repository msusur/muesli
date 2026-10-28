import Foundation
import MuesliCore
import MuesliSession
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
    let generator = try await makeCheckedGenerator(configuration)

    if let notice = disclosure(for: backend, baseURL: baseURL) { fputs("Note: \(notice)\n", stderr) }
    return generator
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
    fputs("Summarizing with \(generator.displayName)…\n", stderr)
    let folder = options.has("--no-save") ? nil : directory.map(SessionFolder.init)
    let result = try await summarize(
        transcript, generator: generator, title: options.value("--title"), userNotes: userNotes, saveTo: folder)

    print(result.notes.markdown())
    let usage = result.usage
    let tokens = usage.inputTokens + usage.outputTokens > 0
        ? " · \(usage.inputTokens) in / \(usage.outputTokens) out tokens" : ""
    fputs("Done: \(result.requests) request\(result.requests == 1 ? "" : "s")\(tokens)\n", stderr)

    guard let folder else { return }
    fputs("Saved → \(folder.file("notes.md").path)\n", stderr)
    if result.notes.hasProposals {
        fputs("Next: review and add them to Reminders, Calendar and Mail with\n  muesli actions \"\(folder.url.path)\"\n", stderr)
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
