import Foundation
import MuesliAudio
import MuesliCore
import MuesliTranscribe

/// What to record and how to transcribe it.
public struct RecordingOptions: Sendable {
    /// Capture the microphone ("Me").
    public var microphone = true
    /// Capture what the Mac plays ("Them").
    public var systemAudio = true
    /// Which apps' audio counts as "Them".
    public var scope: SystemAudioCapture.Scope = .everything
    public var engine: Engine = .apple
    public var locale: Locale = .current
    public var whisper = WhisperConfiguration()
    /// Keep the recorded WAVs after Whisper has used them.
    public var keepAudio = false
    /// Where to save. `nil` records without saving anything (Apple engine only).
    public var folder: SessionFolder?
    public var title: String?

    public init() {}
}

/// Something the person recording should know about, as it happens.
public enum RecordingEvent: Sendable {
    /// The on-device speech model for the locale is being downloaded (one time).
    case downloadingSpeechModel
    /// Worth telling the user but not a problem, e.g. a large first download.
    case note(String)
    /// Capture is running.
    case started
    /// Which apps are being captured changed, or system audio hit a problem.
    case systemAudio(SystemAudioCapture.Update)
    /// A peak level in 0...1 for one side, several times a second.
    case level(Speaker, Float)
    /// Something is playing, but the system-audio tap has delivered nothing but
    /// zeros: almost always a missing System Audio Recording permission.
    case systemAudioSilent
    /// A finalized line of the live transcript.
    case segment(TranscriptSegment)
    /// Capture stopped; transcription is being finished.
    case stopping
    case whisper(WhisperProgress)
    /// Whisper failed. The audio is kept in `audioFolder` so it can be retried.
    case whisperFailed(String, audioFolder: URL)
    case audioWriteFailed(String)
}

public enum RecordingError: Error, LocalizedError, Equatable {
    case nothingToRecord
    case whisperNeedsFolder
    case notRecording
    /// Whisper (the only engine) failed; the audio was kept for a retry.
    case whisperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToRecord: "Neither the microphone nor system audio is selected, so there's nothing to record."
        case .whisperNeedsFolder: "Whisper needs to save the recording, so it can't be used without saving."
        case .notRecording: "Not recording."
        case .whisperFailed(let why): "Whisper failed: \(why)"
        }
    }
}

public struct RecordingResult: Sendable {
    public var transcript: Transcript
    /// Where the transcript was saved; `nil` if nothing was saved (no speech, or no folder).
    public var folder: SessionFolder?
    /// Whisper failed and the Apple transcript was used instead.
    public var usedAppleFallback: Bool
}

/// One meeting being recorded: mic and system audio in, transcript out.
///
/// `start()` returns once capture is running; `stop()` finishes transcription,
/// saves the transcript and returns it. Events arrive on an arbitrary thread.
public actor RecordingSession {
    public nonisolated let options: RecordingOptions
    private let onEvent: @Sendable (RecordingEvent) -> Void

    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var tasks: [Task<Void, Error>] = []
    private var recorders: [Speaker: StreamRecorder] = [:]
    private var transcript: Transcript?
    private var sessionStart: UInt64 = 0
    private var locale: Locale
    private var watchdog: Task<Void, Never>?

    public init(options: RecordingOptions, onEvent: @escaping @Sendable (RecordingEvent) -> Void = { _ in }) {
        self.options = options
        self.onEvent = onEvent
        self.locale = options.locale
    }

    private var audioFolder: URL? {
        options.folder?.url.appending(path: SessionAudio.folderName, directoryHint: .isDirectory)
    }

    // MARK: Start

    public func start() async throws {
        guard options.microphone || options.systemAudio else { throw RecordingError.nothingToRecord }
        if options.engine.usesWhisper {
            guard options.folder != nil else { throw RecordingError.whisperNeedsFolder }
            if let note = try preflightWhisper(options.whisper) { onEvent(.note(note)) }
        }

        // Apple's recognizer needs a supported locale; Whisper doesn't, which is
        // the point of using it for languages Apple can't do.
        if options.engine.usesApple {
            let onEvent = onEvent
            locale = try await StreamTranscriber.prepare(locale: options.locale) { _ in onEvent(.downloadingSpeechModel) }
        }
        sessionStart = HostClock.now()
        transcript = Transcript(startedAt: Date(), locale: locale.identifier)

        let mic = MicrophoneCapture()
        let system = SystemAudioCapture(scope: options.scope)
        let onEvent = onEvent
        system.onUpdate = { onEvent(.systemAudio($0)) }
        self.mic = mic
        self.system = system

        // Start system audio first: it's the one that needs a permission prompt.
        if options.systemAudio { try consume(try system.start(), as: .them) }
        if options.microphone {
            do {
                try consume(try await mic.start(), as: .me)
            } catch {
                system.stop()
                throw error
            }
        }
        onEvent(.started)
    }

    /// Set from the audio thread the first time "Them" delivers a non-zero sample.
    private nonisolated let heardSystemAudio = Flag()

    private func consume(_ raw: AsyncStream<AudioChunk>, as speaker: Speaker) throws {
        let onEvent = onEvent
        let heard = heardSystemAudio
        let throttle = LevelThrottle()
        var chunks = AudioLevel.metering(raw) { peak in
            if speaker == .them, peak > 0 { heard.set() }
            if let level = throttle.next(peak) { onEvent(.level(speaker, level)) }
        }
        if options.engine.usesWhisper, let audioFolder {
            let recorder = try StreamRecorder(url: audioFolder.appending(path: speaker == .me ? "mic.wav" : "system.wav"))
            recorders[speaker] = recorder
            chunks = AudioTee.recording(chunks, to: recorder) { error in
                onEvent(.audioWriteFailed(error.localizedDescription))
            }
        }
        if options.engine.usesApple {
            let transcriber = StreamTranscriber(speaker: speaker, locale: locale, sessionStart: sessionStart)
            tasks.append(Task {
                for try await segment in transcriber.transcribe(chunks) {
                    self.add(segment)
                    onEvent(.segment(segment))
                }
            })
        } else {
            tasks.append(Task { for await _ in chunks {} })
        }
        if speaker == .them { startSilenceWatchdog() }
    }

    private func add(_ segment: TranscriptSegment) { transcript?.append(segment) }

    /// If something is playing but every system-audio sample so far was zero, say
    /// so early, rather than after an hour of a one-sided transcript.
    private func startSilenceWatchdog() {
        watchdog?.cancel()
        watchdog = Task {
            for _ in 0 ..< 6 { // check for about a minute
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                guard !self.heardSystemAudio.isSet else { return }
                if Self.capturedAppIsPlaying(scope: self.options.scope) {
                    self.onEvent(.systemAudioSilent)
                    return
                }
            }
        }
    }

    /// Whether an app this recording captures is playing, so its silence means something.
    /// With `--app zoom`, music in another app says nothing about Zoom's tap.
    static func capturedAppIsPlaying(scope: SystemAudioCapture.Scope, processes: [AudioProcess] = AudioProcesses.list()) -> Bool {
        let playing = processes.filter(\.isProducingAudio)
        switch scope {
        case .everything: return !playing.isEmpty
        case .only(let selector): return !selector.resolve(in: playing).isEmpty
        case .excluding(let selector):
            let excluded = Set(selector.resolve(in: processes).map(\.objectID))
            return playing.contains { !excluded.contains($0.objectID) }
        }
    }

    // MARK: Stop

    /// Stops capture, finishes transcription (and Whisper, if chosen), and saves.
    public func stop() async throws -> RecordingResult {
        guard self.transcript != nil else { throw RecordingError.notRecording }
        onEvent(.stopping)
        watchdog?.cancel()
        mic?.stop()
        system?.stop()
        for task in tasks { try await task.value } // the last segments land here
        tasks = []
        guard var transcript = self.transcript else { throw RecordingError.notRecording }
        self.transcript = nil

        var usedAppleFallback = false
        var whisperFailed = false

        if options.engine.usesWhisper, let folder = options.folder, let audioFolder {
            let sessionStart = sessionStart
            let streams = [Speaker.me, .them].compactMap { speaker -> RecordedStream? in
                guard let recorder = recorders[speaker] else { return nil }
                let offset = recorder.firstHostTime.flatMap { $0 == 0 ? nil : HostClock.seconds(from: sessionStart, to: $0) } ?? 0
                return RecordedStream(speaker: speaker, wav: recorder.url, offset: max(0, offset))
            }
            try SessionAudio(streams: streams.map {
                .init(speaker: $0.speaker, file: $0.wav.lastPathComponent, startOffset: $0.offset)
            }).jsonData().write(to: audioFolder.appending(path: SessionAudio.manifestName))

            do {
                let onEvent = onEvent
                let refined = try await runWhisperPass(streams, configuration: options.whisper, startedAt: transcript.startedAt) {
                    onEvent(.whisper($0))
                }
                if options.engine == .appleThenWhisper, !transcript.segments.isEmpty {
                    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
                    try transcript.jsonData().write(to: folder.file("transcript.apple.json"))
                }
                transcript = refined
                if !options.keepAudio { try? FileManager.default.removeItem(at: audioFolder) }
            } catch {
                whisperFailed = true
                onEvent(.whisperFailed(error.localizedDescription, audioFolder: audioFolder))
                if options.engine == .whisper { throw RecordingError.whisperFailed(error.localizedDescription) }
                usedAppleFallback = true
            }
        }

        guard !transcript.segments.isEmpty else {
            if !whisperFailed, !options.keepAudio, let audioFolder { try? FileManager.default.removeItem(at: audioFolder) }
            return RecordingResult(transcript: transcript, folder: nil, usedAppleFallback: usedAppleFallback)
        }
        if let folder = options.folder { try folder.saveTranscript(transcript, title: options.title) }
        return RecordingResult(transcript: transcript, folder: options.folder, usedAppleFallback: usedAppleFallback)
    }

    /// Stops without saving anything, and deletes any audio recorded so far.
    public func discard() async {
        watchdog?.cancel()
        mic?.stop()
        system?.stop()
        for task in tasks { task.cancel() }
        tasks = []
        transcript = nil
        for recorder in recorders.values { recorder.finish() }
        if let audioFolder { try? FileManager.default.removeItem(at: audioFolder) }
        if let folder = options.folder,
           (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder.url)
        }
    }
}

/// A one-way flag, safe to set from an audio thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Keeps the loudest peak over ~100 ms and releases it once per window.
private final class LevelThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var windowStart = Date.distantPast

    func next(_ value: Float) -> Float? {
        lock.withLock {
            peak = max(peak, value)
            let now = Date()
            guard now.timeIntervalSince(windowStart) >= 0.1 else { return nil }
            defer { peak = 0; windowStart = now }
            return peak
        }
    }
}
