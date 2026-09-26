import AVFoundation
import CoreAudio
import Foundation
import MuesliAudio
import MuesliCore
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(transcript).write(to: directory.appending(path: "transcript.json"))
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

// MARK: - record

struct RecordCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        let wantMic = !options.has("--no-mic")
        let wantSystem = !options.has("--no-system")
        guard wantMic || wantSystem else { throw UsageError("--no-mic and --no-system together leave nothing to record") }

        let duration = try options.value("--duration").map { raw -> TimeInterval in
            guard let d = TimeInterval(raw), d > 0 else { throw UsageError("--duration must be a positive number of seconds") }
            return d
        }

        let locale = try await prepareLocale(resolveLocale(options))
        let sessionStart = HostClock.now()
        let startedAt = Date()
        let builder = TranscriptBuilder(startedAt: startedAt, locale: locale.identifier)

        let mic = MicrophoneCapture()
        let system = SystemAudioCapture()
        var tasks: [Task<Void, Error>] = []

        func consume(_ chunks: AsyncStream<AudioChunk>, as speaker: Speaker) {
            let transcriber = StreamTranscriber(speaker: speaker, locale: locale, sessionStart: sessionStart)
            tasks.append(Task {
                for try await segment in transcriber.transcribe(chunks) {
                    await builder.add(segment)
                    printLive(segment)
                }
            })
        }

        // Start system audio first: it's the one that needs a permission prompt.
        if wantSystem { consume(try system.start(), as: .them) }
        if wantMic {
            do {
                consume(try await mic.start(), as: .me)
            } catch {
                system.stop()
                throw error
            }
        }

        let sources = [wantMic ? "mic (Me)" : nil, wantSystem ? "system audio (Them)" : nil].compactMap { $0 }.joined(separator: " + ")
        fputs("Recording \(sources) — \(locale.identifier). Press Ctrl-C to stop.\n", stderr)
        if wantMic && wantSystem {
            fputs("Tip: use headphones, or your mic will also pick up the other side from your speakers.\n", stderr)
        }

        await waitForStop(after: duration)

        fputs("\nStopping, finalizing transcript…\n", stderr)
        mic.stop()
        system.stop()
        for task in tasks { try await task.value }

        let transcript = await builder.transcript
        guard !transcript.segments.isEmpty else {
            fputs("No speech was recognized, so nothing was saved.\n", stderr)
            return
        }
        if !options.has("--no-save") {
            let directory = options.value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? defaultOutputDirectory(for: startedAt)
            try save(transcript, title: options.value("--title"), to: directory)
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

// MARK: - transcribe

struct TranscribeCommand {
    let options: Options

    init(_ options: Options) { self.options = options }

    func run() async throws {
        guard let path = options.positional.first else { throw UsageError("transcribe needs an audio file") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw UsageError("no such file: \(path)") }

        let speaker: Speaker
        switch options.value("--speaker")?.lowercased() {
        case nil, "them": speaker = .them
        case "me": speaker = .me
        default: throw UsageError("--speaker must be “me” or “them”")
        }

        let locale = try await prepareLocale(resolveLocale(options))
        let startedAt = Date()
        let builder = TranscriptBuilder(startedAt: startedAt, locale: locale.identifier)
        let transcriber = StreamTranscriber(speaker: speaker, locale: locale)

        for try await segment in transcriber.transcribe(try AudioFileSource.chunks(url: url)) {
            await builder.add(segment)
            printLive(segment)
        }

        let transcript = await builder.transcript
        if let out = options.value("--out"), !options.has("--no-save") {
            try save(transcript, title: options.value("--title") ?? url.deletingPathExtension().lastPathComponent,
                     to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        }
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
