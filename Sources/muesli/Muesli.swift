import Foundation

@main
struct Muesli {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch is ExitFailure {
            exit(1)
        } catch let error as UsageError {
            fputs("muesli: \(error.message)\n\n\(usage)\n", stderr)
            exit(64)
        } catch {
            fputs("muesli: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        guard let command = args.first else {
            print(usage)
            return
        }
        let rest = Array(args.dropFirst())
        switch command {
        case "record":
            try await RecordCommand(Options(rest)).run()
        case "transcribe":
            try await TranscribeCommand(Options(rest)).run()
        case "summarize":
            try await SummarizeCommand(Options(rest)).run()
        case "apps":
            AppsCommand(try Options(rest)).run()
        case "actions":
            try await ActionsCommand(Options(rest)).run()
        case "undo":
            try await UndoCommand(Options(rest)).run()
        case "doctor":
            await DoctorCommand().run()
        case "-h", "--help", "help":
            print(usage)
        case "--version", "version":
            print("muesli \(version)")
        default:
            throw UsageError("unknown command “\(command)”")
        }
    }
}

let version = "0.1.0"

let usage = """
muesli — open-source meeting notes, on your Mac.

USAGE
  muesli record [options]          Capture mic + system audio and transcribe live.
                                   Press Ctrl-C (or use --duration) to stop and save.
  muesli transcribe <audio-file>   Transcribe an existing audio file.
  muesli summarize <transcript>    Turn a transcript.json (or its folder) into notes:
                                   summary, decisions, action items, events, email drafts.
  muesli actions <session>         Review the notes' action items, events and email drafts,
                                   then add the ones you approve to Reminders, Calendar
                                   and your mail app. Nothing is created without your OK.
  muesli undo <session>            Remove the reminders and events muesli added.
  muesli apps                      List apps that are playing audio (for --app).
  muesli doctor                    Check permissions, speech models and summarizers.

COMMON OPTIONS
  --locale <id>       Speech locale, e.g. en-US, en-GB, fr-FR   (default: your system locale)
  --out <dir>         Where to save files (default: ~/Muesli/<date-time>)
  --title <text>      Title for the meeting
  --no-save           Print only; don't write files

RECORD
  --duration <secs>   Stop automatically after this many seconds
  --no-mic            Don't capture the microphone ("Me")
  --no-system         Don't capture system audio ("Them")
  --app <names>       Capture system audio from only these apps (comma-separated names or
                      bundle ids, e.g. "zoom" or "Google Chrome"). Follows the app as it
                      starts playing audio. See `muesli apps`.
  --exclude-app <n>   Capture all system audio except these apps (e.g. "Music,Spotify")
  --summarize         Also write notes.md / notes.json when recording ends

TRANSCRIBE
  --speaker <me|them> Label for the file's speaker (default: them)

SUMMARIZE (also used by `record --summarize`)
  --backend <name>    apple         Apple's on-device model (default when available)
                      apple-cloud   Apple Private Cloud Compute (macOS 27+)
                      anthropic     Claude, using $ANTHROPIC_API_KEY
                      openai        Any OpenAI-compatible server: llama.cpp, Ollama, LM Studio
  --model <name>      Model to use (anthropic default: claude-opus-5; required for openai)
  --notes <file>      Your own rough notes; muesli expands them using the transcript
  --base-url <url>    openai: server URL, e.g. http://localhost:11434/v1
  --context-tokens N  openai: the server's real context window (default 8192)
  --api-key-env NAME  openai: environment variable holding a bearer token, if needed
  --no-fallback       anthropic: don't retry refusals on Anthropic's fallback model

ACTIONS
  --dry-run           Show what would be proposed; create nothing
  --yes               Apply the pre-checked items without asking (use in scripts)
  --all               Apply every proposed item without asking
  --only <kinds>      reminders, events, emails (comma-separated)
  --reminders-list N  Reminders list to use (default: your default list)
  --calendar NAME     Calendar to use (default: your default calendar)
  --force             Propose items even if they were added before

Transcripts only leave your Mac if you choose anthropic, apple-cloud or a remote openai server.
"""

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Minimal flag parser — enough for three commands without a dependency.
struct Options {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positional: [String] = []

    private static let valueFlags: Set<String> = [
        "--locale", "--out", "--title", "--duration", "--speaker",
        "--backend", "--model", "--base-url", "--context-tokens", "--api-key-env", "--notes",
        "--only", "--reminders-list", "--calendar", "--app", "--exclude-app",
    ]

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if Self.valueFlags.contains(arg) {
                guard i + 1 < args.count else { throw UsageError("\(arg) needs a value") }
                values[arg] = args[i + 1]
                i += 2
            } else if arg.hasPrefix("--") {
                flags.insert(arg)
                i += 1
            } else {
                positional.append(arg)
                i += 1
            }
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ flag: String) -> String? { values[flag] }
}
