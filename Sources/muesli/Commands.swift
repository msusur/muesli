import AVFoundation
import CoreAudio
import Foundation
import MuesliAudio
import MuesliActions
import MuesliCore
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

private func defaultOutputDirectory(for date: Date) -> URL {
    let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        .replacingOccurrences(of: "T", with: "-")
    return FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Muesli", directoryHint: .isDirectory)
        .appending(path: stamp, directoryHint: .isDirectory)
}

private func save(_ transcript: Transcript, title: String?, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try transcript.jsonData().write(to: directory.appending(path: "transcript.json"))
    try transcript.markdown(title: title).write(to: directory.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
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
        let keepAudio = options.has("--keep-audio")

        let duration = try options.value("--duration").map { raw -> TimeInterval in
            guard let d = TimeInterval(raw), d > 0 else { throw UsageError("--duration must be a positive number of seconds") }
            return d
        }

        // Fail now, not after an hour-long meeting, if something can't work.
        let generator = options.has("--summarize") ? try await makeGenerator(options) : nil
        let whisper = whisperConfiguration(options)
        if engine.usesWhisper {
            guard !options.has("--no-save") else {
                throw UsageError("--engine whisper needs to save the recording, so it can't be combined with --no-save")
            }
            try preflightWhisper(whisper)
        }

        // Apple's recognizer needs a supported locale; Whisper doesn't, which is
        // the point of using it for languages Apple can't do.
        let locale = engine.usesApple ? try await prepareLocale(resolveLocale(options)) : resolveLocale(options)
        let sessionStart = HostClock.now()
        let startedAt = Date()
        let builder = TranscriptBuilder(startedAt: startedAt, locale: locale.identifier)
        let directory = options.has("--no-save") ? nil : (
            options.value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? defaultOutputDirectory(for: startedAt))
        let audioFolder = directory?.appending(path: SessionAudio.folderName, directoryHint: .isDirectory)

        let mic = MicrophoneCapture()
        let system = SystemAudioCapture(scope: scope)
        system.onUpdate = { update in
            switch (update, scope) {
            case (.waiting(let terms), _):
                fputs("Waiting for audio from \(terms.map { "“\($0)”" }.joined(separator: ", "))… start your call and muesli will pick it up.\n", stderr)
            case (.following(let names), .only):
                fputs("Capturing only: \(names.joined(separator: ", "))\n", stderr)
            case (.following(let names), .excluding) where !names.isEmpty:
                fputs("Capturing everything except: \(names.joined(separator: ", "))\n", stderr)
            case (.failed(let why), _):
                fputs("System audio problem: \(why)\n", stderr)
            default:
                break
            }
        }

        var tasks: [Task<Void, Error>] = []
        var recorders: [Speaker: StreamRecorder] = [:]

        func consume(_ raw: AsyncStream<AudioChunk>, as speaker: Speaker) throws {
            var chunks = raw
            if engine.usesWhisper, let audioFolder {
                let recorder = try StreamRecorder(url: audioFolder.appending(path: speaker == .me ? "mic.wav" : "system.wav"))
                recorders[speaker] = recorder
                chunks = AudioTee.recording(raw, to: recorder) { error in
                    fputs("Couldn't write audio: \(error.localizedDescription)\n", stderr)
                }
            }
            if engine.usesApple {
                let transcriber = StreamTranscriber(speaker: speaker, locale: locale, sessionStart: sessionStart)
                tasks.append(Task {
                    for try await segment in transcriber.transcribe(chunks) {
                        await builder.add(segment)
                        printLive(segment)
                    }
                })
            } else {
                tasks.append(Task { for await _ in chunks {} })
            }
        }

        // Start system audio first: it's the one that needs a permission prompt.
        if wantSystem { try consume(try system.start(), as: .them) }
        if wantMic {
            do {
                try consume(try await mic.start(), as: .me)
            } catch {
                system.stop()
                throw error
            }
        }

        let systemLabel: String = switch scope {
        case .everything: "system audio (Them)"
        case .only(let apps): "audio from \(apps.terms.joined(separator: ", ")) (Them)"
        case .excluding(let apps): "system audio except \(apps.terms.joined(separator: ", ")) (Them)"
        }
        let sources = [wantMic ? "mic (Me)" : nil, wantSystem ? systemLabel : nil].compactMap { $0 }.joined(separator: " + ")
        fputs("Recording \(sources) — \(engine.usesApple ? locale.identifier : "Whisper"). Press Ctrl-C to stop.\n", stderr)
        if engine == .whisper { fputs("Whisper transcribes after you stop, so there's no live text.\n", stderr) }
        if wantMic && wantSystem {
            fputs("Tip: use headphones, or your mic will also pick up the other side from your speakers.\n", stderr)
        }

        await waitForStop(after: duration)

        fputs("\nStopping…\n", stderr)
        mic.stop()
        system.stop()
        for task in tasks { try await task.value }

        var transcript = await builder.transcript
        var whisperFailed = false

        if engine.usesWhisper, let directory {
            let streams = [Speaker.me, .them].compactMap { speaker -> RecordedStream? in
                guard let recorder = recorders[speaker] else { return nil }
                let offset = recorder.firstHostTime.flatMap { $0 == 0 ? nil : HostClock.seconds(from: sessionStart, to: $0) } ?? 0
                return RecordedStream(speaker: speaker, wav: recorder.url, offset: max(0, offset))
            }
            try SessionAudio(streams: streams.map {
                .init(speaker: $0.speaker, file: $0.wav.lastPathComponent, startOffset: $0.offset)
            }).jsonData().write(to: directory.appending(path: "\(SessionAudio.folderName)/\(SessionAudio.manifestName)"))

            do {
                let refined = try await runWhisperPass(streams, configuration: whisper, startedAt: startedAt)
                if engine == .appleThenWhisper, !transcript.segments.isEmpty {
                    try transcript.jsonData().write(to: directory.appending(path: "transcript.apple.json"))
                }
                transcript = refined
                if engine == .whisper { printSegments(transcript) }
                if !keepAudio { try? FileManager.default.removeItem(at: audioFolder!) }
            } catch {
                whisperFailed = true
                fputs("Whisper failed: \(error.localizedDescription)\nYour audio is kept in \(audioFolder!.path). Retry with:\n  muesli transcribe \"\(directory.path)\" --engine whisper\n", stderr)
                if engine == .whisper { throw ExitFailure() }
                fputs("Using the live Apple transcript instead.\n", stderr)
            }
        }

        guard !transcript.segments.isEmpty else {
            fputs("No speech was recognized, so nothing was saved.\n", stderr)
            if !whisperFailed, !keepAudio, let audioFolder { try? FileManager.default.removeItem(at: audioFolder) }
            return
        }
        if let directory { try save(transcript, title: options.value("--title"), to: directory) }

        if let generator {
            do {
                try await summarizeAndSave(transcript, generator: generator, options: options, directory: directory)
            } catch {
                // The recording is safe; say how to retry rather than losing the meeting to a network blip.
                let retry = directory.map { "muesli summarize \"\($0.path)\" --backend \(options.value("--backend") ?? "…")" } ?? "muesli summarize <transcript.json>"
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
            try preflightWhisper(configuration)
            let scratch = FileManager.default.temporaryDirectory.appending(path: "muesli-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let wav = scratch.appending(path: "audio.wav")
            try await convertToWAV(url, to: wav)
            let transcript = try await runWhisperPass(
                [RecordedStream(speaker: speaker, wav: wav, offset: 0)], configuration: configuration, startedAt: Date())
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
        try preflightWhisper(configuration)

        let audioFolder = session.appending(path: SessionAudio.folderName)
        let streams = manifest.streams.map { RecordedStream(speaker: $0.speaker, wav: audioFolder.appending(path: $0.file), offset: $0.startOffset) }
        let startedAt = (try? Transcript.load(jsonData: Data(contentsOf: session.appending(path: "transcript.json"))))?.startedAt ?? Date()
        let transcript = try await runWhisperPass(streams, configuration: configuration, startedAt: startedAt)
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

        // Speech
        let available = SpeechTranscriber.isAvailable
        print("\(mark(available)) On-device speech transcription available")
        if available {
            let locale = Locale.current
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                let status = await AssetInventory.status(forModules: [module])
                // Not installed isn't a failure: the model downloads on first use.
                let symbol = status == .installed ? "✓" : "•"
                print("\(symbol) Speech model for \(supported.identifier): \(status)"
                    + (status == .installed ? "" : "  (downloads automatically on first use)"))
            } else {
                print("\(mark(false)) Locale \(locale.identifier) isn't supported by SpeechTranscriber; pass --locale")
            }
        }

        // Microphone
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micText: String = switch mic {
        case .authorized: "granted"
        case .notDetermined: "not asked yet (you'll be prompted on first record)"
        case .denied: "DENIED — enable your terminal in System Settings → Privacy & Security → Microphone"
        case .restricted: "restricted by policy"
        @unknown default: "unknown"
        }
        print("\(mark(mic == .authorized || mic == .notDetermined)) Microphone: \(micText)")

        // Whisper (optional second speech engine)
        print("Whisper (optional engine for more languages):")
        let whisperDefaults = WhisperConfiguration()
        if let python = try? WhisperTranscriber(configuration: whisperDefaults).resolvePython() {
            print("  ✓ mlx-whisper found (\(python))")
            let cached = WhisperTranscriber.isModelCached(whisperDefaults.model)
            print("  \(cached ? "✓" : "•") \(whisperDefaults.model): \(cached ? "downloaded" : "not downloaded yet (about 3 GB on first use)")")
        } else {
            print("  • mlx-whisper not found. To enable: python3 -m pip install mlx-whisper")
        }

        // Reminders and Calendar (status only; never prompts)
        for (kind, name) in [(ProposedAction.Kind.reminder, "Reminders"), (.event, "Calendar")] {
            let access = EventKitApplier.access(for: kind)
            let text: String = switch access {
            case .granted: "granted"
            case .notDetermined: "not asked yet (you'll be prompted the first time you run `muesli actions`)"
            case .denied: "DENIED — enable your terminal in System Settings → Privacy & Security → \(name == "Calendar" ? "Calendars" : name)"
            case .restricted: "restricted by policy"
            case .writeOnly: "write-only (muesli needs full access to pick a list and undo)"
            }
            print("\(access == .granted || access == .notDetermined ? "✓" : "✗") \(name): \(text)")
        }

        // Summarizers
        print("Summarizers:")
        for kind in [AppleGenerator.Kind.onDevice, .privateCloud] {
            let generator = AppleGenerator(kind: kind)
            let name = kind == .onDevice ? "apple        (on-device)" : "apple-cloud  (Private Cloud Compute)"
            if let reason = AppleGenerator.unavailableReason(kind) {
                print("  ✗ \(name): \(reason)")
            } else {
                let context = await generator.contextTokens().map { ", \($0) token context" } ?? ""
                print("  ✓ \(name)\(context)")
            }
        }
        let hasKey = !(ProcessInfo.processInfo.environment[AnthropicGenerator.apiKeyEnvironmentVariable] ?? "").isEmpty
        print("  \(hasKey ? "✓" : "•") anthropic    (\(AnthropicGenerator.apiKeyEnvironmentVariable) \(hasKey ? "is set" : "not set"); default model \(AnthropicGenerator.defaultModel))")
        print("  • openai       (any OpenAI-compatible server; pass --base-url and --model)")
        if let automatic = Backend.automatic() {
            print("  Default: \(automatic.rawValue)")
        } else {
            print("  Default: none; pass --backend")
        }

        // System audio
        do {
            let uid = try SystemAudioCapture.defaultOutputDeviceUID()
            print("\(mark(true)) Default output device: \(uid)")
            let probe = SystemAudioCapture()
            _ = try probe.start()
            probe.stop()
            print("\(mark(true)) System-audio tap: can be created")
        } catch {
            print("\(mark(false)) System-audio tap: \(error.localizedDescription)")
        }
    }

    private func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
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
