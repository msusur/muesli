import Foundation

@main
struct Muesli {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
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
  muesli record [options]        Capture mic + system audio and transcribe live.
                                 Press Ctrl-C (or use --duration) to stop and save.
  muesli transcribe <audio-file> Transcribe an existing audio file.
  muesli doctor                  Check permissions, speech models and audio devices.

OPTIONS
  --locale <id>      Speech locale, e.g. en-US, en-GB, fr-FR   (default: your system locale)
  --out <dir>        Where to save transcript.md / transcript.json
                     (default: ~/Muesli/<date-time>)
  --title <text>     Title for the saved transcript
  --duration <secs>  record: stop automatically after this many seconds
  --no-mic           record: don't capture the microphone ("Me")
  --no-system        record: don't capture system audio ("Them")
  --speaker <me|them> transcribe: label for the file's speaker (default: them)
  --no-save          Print only; don't write files
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

    private static let valueFlags: Set<String> = ["--locale", "--out", "--title", "--duration", "--speaker"]

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
