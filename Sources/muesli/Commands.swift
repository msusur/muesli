import AVFoundation
import CoreAudio
import Foundation
import MuesliAudio
import MuesliActions
import MuesliCore
import MuesliSession
import MuesliSummarize
import MuesliTranscribe
import os
import Speech

// MARK: - Shared helpers

private func resolveLocale(_ options: Options) -> Locale {
    options.value("--locale").map { Locale(identifier: $0) } ?? Locale.current
}

/// Downloads the on-device speech model on first use.
private func prepareLocale(_ requested: Locale) async throws -> Locale {
    let locale = try await StreamTranscriber.prepare(locale: requested) { progress in
        fputs("Downloading speech model (one-time)…\n", stderr)
    }
    return locale
}

private func save(_ transcript: Transcript, title: String?, to directory: URL) throws {
    try SessionFolder(directory).saveTranscript(transcript, title: title)
    print("Saved → \(directory.path)")
}

private actor TranscriptBuilder {
    private(set) var transcript: Transcript
    init(startedAt: Date, locale: String) { transcript = Transcript(startedAt: startedAt, locale: locale) }
    func add(_ segment: TranscriptSegment) { transcript.append(segment) }
}

private func printLive(_ segment: TranscriptSegment) {
    print("[\(Transcript.timestamp(segment.start))] \(segment.speaker.label): \(segment.text)")
    fflush(stdout)
}

/// `--app` / `--exclude-app`, validated. Nothing is captured until this passes.
private func systemScope(_ options: Options, wantSystem: Bool) throws -> SystemAudioCapture.Scope {
    let only = options.value("--app").map(AppSelector.init(commaSeparated:))
    let excluding = options.value("--exclude-app").map(AppSelector.init(commaSeparated:))
    if only != nil && excluding != nil { throw UsageError("use either --app or --exclude-app, not both") }
    if !wantSystem, only != nil || excluding != nil { throw UsageError("--app and --exclude-app choose system audio, but --no-system turns it off") }
    if let only { guard !only.isEmpty else { throw UsageError("--app needs at least one app name or bundle id") }; return .only(only) }
    if let excluding { guard !excluding.isEmpty else { throw UsageError("--exclude-app needs at least one app name or bundle id") }; return .excluding(excluding) }
    return .everything
}

// MARK: - record

struct RecordCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        let wantMic = !options.has("--no-mic")
        let wantSystem = !options.has("--no-system")
        guard wantMic || wantSystem else { throw UsageError("--no-mic and --no-system together leave nothing to record") }
        let scope = try systemScope(options, wantSystem: wantSystem)
        let engine = try Engine(options)

        let duration = try options.value("--duration").map { raw -> TimeInterval in
            guard let d = TimeInterval(raw), d > 0 else { throw UsageError("--duration must be a positive number of seconds") }
            return d
        }

        // Fail now, not after an hour-long meeting, if something can't work.
        let generator = options.has("--summarize") ? try await makeGenerator(options) : nil
        if engine.usesWhisper, options.has("--no-save") {
            throw UsageError("--engine whisper needs to save the recording, so it can't be combined with --no-save")
        }

        var recording = RecordingOptions()
        recording.microphone = wantMic
        recording.systemAudio = wantSystem
        recording.scope = scope
        recording.engine = engine
        recording.locale = resolveLocale(options)
        recording.whisper = whisperConfiguration(options)
        recording.keepAudio = options.has("--keep-audio")
        recording.title = options.value("--title")
        let startedAt = Date()
        recording.folder = options.has("--no-save") ? nil : (
            options.value("--out").map { SessionFolder(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
                ?? SessionFolder.new(startedAt: startedAt))

        let session = RecordingSession(options: recording) { event in
            switch event {
            case .downloadingSpeechModel: fputs("Downloading speech model (one-time)…\n", stderr)
            case .note(let note): fputs("Note: \(note)\n", stderr)
            case .systemAudio(.waiting(let terms)):
                fputs("Waiting for audio from \(terms.map { "“\($0)”" }.joined(separator: ", "))… start your call and muesli will pick it up.\n", stderr)
            case .systemAudio(.following(let names)):
                switch scope {
                case .only: fputs("Capturing only: \(names.joined(separator: ", "))\n", stderr)
                case .excluding where !names.isEmpty: fputs("Capturing everything except: \(names.joined(separator: ", "))\n", stderr)
                default: break
                }
            case .systemAudio(.failed(let why)): fputs("System audio problem: \(why)\n", stderr)
            case .systemAudioSilent:
                fputs("""
                    Warning: something is playing, but system audio (Them) is completely silent.
                    Allow your terminal in System Settings → Privacy & Security → Screen & System Audio Recording,
                    then restart the recording.\n
                    """, stderr)
            case .segment(let segment): printLive(segment)
            case .whisper(let progress): printWhisperProgress(progress)
            case .whisperFailed(let why, let audioFolder):
                fputs("Whisper failed: \(why)\nYour audio is kept in \(audioFolder.path). Retry with:\n  muesli transcribe \"\(audioFolder.deletingLastPathComponent().path)\" --engine whisper\n", stderr)
                if engine != .whisper { fputs("Using the live Apple transcript instead.\n", stderr) }
            case .audioWriteFailed(let why): fputs("Couldn't write audio: \(why)\n", stderr)
            case .started, .level, .stopping, .systemAudio: break
            }
        }
        try await session.start()

        let systemLabel: String = switch scope {
        case .everything: "system audio (Them)"
        case .only(let apps): "audio from \(apps.terms.joined(separator: ", ")) (Them)"
        case .excluding(let apps): "system audio except \(apps.terms.joined(separator: ", ")) (Them)"
        }
        let sources = [wantMic ? "mic (Me)" : nil, wantSystem ? systemLabel : nil].compactMap { $0 }.joined(separator: " + ")
        fputs("Recording \(sources) — \(engine.usesApple ? recording.locale.identifier : "Whisper"). Press Ctrl-C to stop.\n", stderr)
        if engine == .whisper { fputs("Whisper transcribes after you stop, so there's no live text.\n", stderr) }
        if wantMic && wantSystem {
            fputs("Tip: use headphones, or your mic will also pick up the other side from your speakers.\n", stderr)
        }

        await waitForStop(after: duration)
        fputs("\nStopping…\n", stderr)

        let result: RecordingResult
        do { result = try await session.stop() } catch RecordingError.whisperFailed { throw ExitFailure() }
        if engine == .whisper { printSegments(result.transcript) }

        guard !result.transcript.segments.isEmpty else {
            fputs("No speech was recognized, so nothing was saved.\n", stderr)
            return
        }
        if let folder = result.folder { print("Saved → \(folder.url.path)") }

        if let generator {
            do {
                try await summarizeAndSave(result.transcript, generator: generator, options: options, directory: result.folder?.url)
            } catch {
                // The recording is safe; say how to retry rather than losing the meeting to a network blip.
                let retry = result.folder.map { "muesli summarize \"\($0.url.path)\" --backend \(options.value("--backend") ?? "…")" }
                    ?? "muesli summarize <transcript.json>"
                fputs("Summarizing failed: \(error.localizedDescription)\nYour transcript is saved. Retry with:\n  \(retry)\n", stderr)
                throw ExitFailure()
            }
        }
    }

    /// Returns on the first Ctrl-C or when `duration` elapses. A second Ctrl-C
    /// while finalizing exits immediately.
    private func waitForStop(after duration: TimeInterval?) async {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let interrupts = OSAllocatedUnfairLock(initialState: 0)
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            let count = interrupts.withLock { n -> Int in n += 1; return n }
            if count == 1 { continuation.yield() } else { exit(130) }
        }
        source.resume()
        if let duration {
            Task {
                try? await Task.sleep(for: .seconds(duration))
                continuation.yield()
            }
        }
        for await _ in stream { break }
    }
}

/// Already reported to the user; just set a non-zero exit code.
struct ExitFailure: Error {}

// MARK: - transcribe

struct TranscribeCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        guard let path = options.positional.first else { throw UsageError("transcribe needs an audio file, or a session folder to re-transcribe") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw UsageError("no such file: \(path)") }

        // A session folder can only be re-transcribed from its recorded audio, which is Whisper's job.
        let engine = isDirectory.boolValue && options.value("--engine") == nil ? Engine.whisper : try Engine(options)
        if isDirectory.boolValue {
            guard engine == .whisper else { throw UsageError("a session folder is re-transcribed with --engine whisper") }
            try await retranscribe(session: url)
            return
        }

        let speaker: Speaker
        switch options.value("--speaker")?.lowercased() {
        case nil, "them": speaker = .them
        case "me": speaker = .me
        default: throw UsageError("--speaker must be “me” or “them”")
        }

        if engine == .whisper {
            let configuration = whisperConfiguration(options)
            try checkWhisper(configuration)
            let scratch = FileManager.default.temporaryDirectory.appending(path: "muesli-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let wav = scratch.appending(path: "audio.wav")
            try await convertToWAV(url, to: wav)
            let transcript = try await runWhisperPass(
                [RecordedStream(speaker: speaker, wav: wav, offset: 0)], configuration: configuration, startedAt: Date(),
                progress: printWhisperProgress)
            printSegments(transcript)
            try saveIfRequested(transcript, defaultTitle: url.deletingPathExtension().lastPathComponent)
            return
        }

        let locale = try await prepareLocale(resolveLocale(options))
        let startedAt = Date()
        let builder = TranscriptBuilder(startedAt: startedAt, locale: locale.identifier)
        let transcriber = StreamTranscriber(speaker: speaker, locale: locale)

        for try await segment in transcriber.transcribe(try AudioFileSource.chunks(url: url)) {
            await builder.add(segment)
            printLive(segment)
        }
        try saveIfRequested(await builder.transcript, defaultTitle: url.deletingPathExtension().lastPathComponent)
    }

    private func saveIfRequested(_ transcript: Transcript, defaultTitle: String) throws {
        guard let out = options.value("--out"), !options.has("--no-save") else { return }
        try save(transcript, title: options.value("--title") ?? defaultTitle,
                 to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
    }

    /// Re-runs Whisper over a session's retained audio and rewrites its transcript.
    private func retranscribe(session: URL) async throws {
        let manifestURL = session.appending(path: "\(SessionAudio.folderName)/\(SessionAudio.manifestName)")
        guard let data = try? Data(contentsOf: manifestURL), let manifest = try? SessionAudio.load(jsonData: data) else {
            throw UsageError("\(session.path) has no recorded audio. Record with --engine whisper --keep-audio to keep it.")
        }
        let configuration = whisperConfiguration(options)
        try checkWhisper(configuration)

        let audioFolder = session.appending(path: SessionAudio.folderName)
        let streams = manifest.streams.map { RecordedStream(speaker: $0.speaker, wav: audioFolder.appending(path: $0.file), offset: $0.startOffset) }
        let startedAt = (try? Transcript.load(jsonData: Data(contentsOf: session.appending(path: "transcript.json"))))?.startedAt ?? Date()
        let transcript = try await runWhisperPass(streams, configuration: configuration, startedAt: startedAt, progress: printWhisperProgress)
        guard !transcript.segments.isEmpty else {
            fputs("Whisper found no speech in the recording.\n", stderr)
            return
        }
        printSegments(transcript)
        if !options.has("--no-save") { try save(transcript, title: options.value("--title"), to: session) }
    }
}

// MARK: - doctor

struct DoctorCommand {
    func run() async {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        print("muesli \(version) — macOS \(os)")
        var section: SetupCheck.Section?
        for check in await SetupChecks.run(grantee: "your terminal") {
            if check.section != section {
                section = check.section
                print("\(check.section.rawValue):")
            }
            let mark = switch check.status {
            case .ok: "✓"
            case .info: "•"
            case .problem: "✗"
            }
            print("  \(mark) \(check.title): \(check.detail)")
        }
        if let automatic = Backend.automatic() {
            print("Default summarizer: \(automatic.rawValue)")
        } else {
            print("Default summarizer: none; pass --backend")
        }
    }
}

// MARK: - apps

struct AppsCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() {
        let all = AudioProcesses.list()
        let shown = options.has("--all") ? all : all.filter(\.isProducingAudio)
        guard !shown.isEmpty else {
            print(all.isEmpty
                ? "No audio processes found."
                : "Nothing is playing audio right now. Start your call or media, then run this again (or use --all).")
            return
        }
        print("\(options.has("--all") ? "Audio processes" : "Playing audio now"):")
        for p in shown.sorted(by: { ($0.isProducingAudio ? 0 : 1, $0.name.lowercased()) < ($1.isProducingAudio ? 0 : 1, $1.name.lowercased()) }) {
            let bundle = p.bundleID.map { "  \($0)" } ?? ""
            print("  \(p.isProducingAudio ? "▶" : " ") \(p.name)  (pid \(p.pid))\(bundle)")
        }
        print("\nCapture just these with:  muesli record --app \"<name or bundle id>\"")
    }
}
