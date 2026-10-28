import AppKit
import Foundation
import MuesliAudio
import MuesliCore
import MuesliSession
import MuesliSummarize
import MuesliTranscribe
import Observation
import Speech

/// Where "Them" comes from.
enum SystemSource: Hashable {
    /// Everything the Mac plays, minus the apps excluded in Settings.
    case everything
    /// One app (and its helper processes), by name.
    case app(String)
    /// No system audio: microphone only.
    case none
}

/// Everything the menu, the live panel and the windows show, and the actions behind them.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        /// Getting ready: model download, permission prompts.
        case starting(String)
        case recording
        /// Finishing transcription, Whisper, or summarizing.
        case finishing(String)

        var isBusy: Bool { self != .idle }
    }

    let preferences = Preferences()

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    /// Advances once a second while recording, for the elapsed-time display.
    private(set) var now = Date()
    private(set) var title: String?

    // Live recording state
    private(set) var segments: [TranscriptSegment] = []
    private(set) var levels: [Speaker: Float] = [:]
    private(set) var captureNote: String?
    /// Something is playing but "Them" is digital silence: almost always the permission.
    private(set) var systemAudioSilent = false
    private(set) var recordingNotes: [String] = []
    /// When the transcript in `segments` began. Unlike `startedAt` it outlives
    /// the recording, so the last transcript can still be copied and asked about.
    private(set) var transcriptStartedAt: Date?
    let ask = AskModel()
    /// Briefly true after Copy All, for the button's "Copied" confirmation.
    private(set) var transcriptCopied = false

    // Menu data
    var source: SystemSource = .everything
    private(set) var playingApps: [String] = []
    private(set) var microphones: [InputDevice] = []
    private(set) var defaultMicrophone: InputDevice?
    private(set) var recent: [RecentSession] = []
    private(set) var supportedLocales: [Locale] = []
    private(set) var whisperAvailable = false

    /// Sessions whose notes have proposals nobody has reviewed yet.
    private(set) var awaitingReview: Set<URL> = []

    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var generator: (any NotesGenerator)?
    @ObservationIgnored private var events: AsyncStream<RecordingEvent>.Continuation?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var quitWhenIdle = false

    let windows = WindowManager()
    let notifier = Notifier()

    init() {
        notifier.onOpen = { [weak self] url, review in
            guard let self else { return }
            if review { self.openReview(url) } else { self.openNotes(url) }
        }
        refreshMenuData()
        refresher = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                tick += 1
                self?.refreshMenuData(includingRecent: tick % 6 == 0)
            }
        }
        Task { await loadCapabilities() }
        // Ask for the microphone now, not halfway into the first meeting. macOS
        // only shows the prompt once; after that this just reads the answer.
        Task { _ = await MicrophoneCapture.requestAccess() }
    }

    // MARK: Menu data

    /// What's playing and the next meeting are cheap and change often; recent
    /// sessions read files, so they're refreshed less often and after each change.
    func refreshMenuData(includingRecent: Bool = true) {
        if phase == .idle {
            playingApps = Set(AudioProcesses.list().filter(\.isProducingAudio).map(Self.appName)).sorted()
            microphones = InputDevices.list()
            defaultMicrophone = InputDevices.systemDefault()
        }
        if includingRecent { recent = SessionFolder.recent(in: preferences.outputRoot, limit: 8).map(RecentSession.init) }
    }

    /// "Google Chrome Helper (Renderer)" → "Google Chrome"; helpers are captured with their app anyway.
    private static func appName(_ process: AudioProcess) -> String {
        if let range = process.name.range(of: " Helper") { return String(process.name[..<range.lowerBound]) }
        return process.name
    }

    private func loadCapabilities() async {
        let locales = await SpeechTranscriber.supportedLocales
        supportedLocales = locales.sorted { $0.localizedName < $1.localizedName }
        let python = preferences.pythonPath
        whisperAvailable = await Task.detached {
            (try? WhisperTranscriber(configuration: WhisperConfiguration(python: python.isEmpty ? nil : python)).resolvePython()) != nil
        }.value
    }

    // MARK: Recording

    var elapsed: TimeInterval { startedAt.map { now.timeIntervalSince($0) } ?? 0 }

    var canStart: Bool { phase == .idle && (preferences.useMicrophone || source != .none) }

    var sourceDescription: String {
        let them: String? = switch source {
        case .everything: "System Audio"
        case .app(let name): name
        case .none: nil
        }
        return [preferences.useMicrophone ? microphoneName : nil, them].compactMap { $0 }.joined(separator: " + ")
    }

    /// The chosen microphone if it's connected. One that isn't falls back to the
    /// system default, rather than refusing to record.
    var chosenMicrophone: InputDevice? {
        preferences.microphoneUID.flatMap { uid in microphones.first { $0.uid == uid } }
    }

    /// The device "Me" will be recorded from.
    var microphoneName: String { (chosenMicrophone ?? defaultMicrophone)?.name ?? "Mic" }

    func start(title: String? = nil) {
        guard canStart else { return }
        let prefs = preferences
        self.title = title
        segments = []
        transcriptStartedAt = nil
        ask.clear()
        levels = [:]
        captureNote = nil
        systemAudioSilent = false
        recordingNotes = []
        phase = .starting("Getting ready…")

        // A microphone may have been plugged in or out since the menu last looked.
        microphones = InputDevices.list()
        defaultMicrophone = InputDevices.systemDefault()
        var options = RecordingOptions()
        options.microphone = prefs.useMicrophone
        options.microphoneDevice = chosenMicrophone?.uid
        if prefs.useMicrophone, prefs.microphoneUID != nil, chosenMicrophone == nil {
            recordingNotes.append("The chosen microphone isn't connected, so \(microphoneName) is used.")
        }
        options.systemAudio = source != .none
        switch source {
        case .everything:
            let excluded = AppSelector(commaSeparated: prefs.excludedApps)
            options.scope = excluded.isEmpty ? .everything : .excluding(excluded)
        case .app(let name): options.scope = .only(AppSelector([name]))
        case .none: break
        }
        options.engine = prefs.engine == .apple || whisperAvailable ? prefs.engine : .apple
        options.locale = prefs.locale
        options.whisper = WhisperConfiguration(
            model: prefs.whisperModel, language: prefs.localeIdentifier.flatMap { Locale(identifier: $0).language.languageCode?.identifier },
            python: prefs.pythonPath.isEmpty ? nil : prefs.pythonPath)
        options.title = title
        options.folder = SessionFolder.new(in: prefs.outputRoot, startedAt: Date())
        if prefs.engine != options.engine { recordingNotes.append("Whisper isn't installed, so Apple's engine is used.") }

        // Events arrive on audio threads; a stream keeps them in order on the main actor.
        let (stream, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
        events = continuation
        Task { for await event in stream { self.handle(event) } }

        let session = RecordingSession(options: options) { continuation.yield($0) }
        self.session = session

        Task {
            // Check the summarizer now, not after the meeting. A problem doesn't stop
            // the recording: losing a meeting is worse than summarizing it later.
            generator = nil
            if prefs.summarizeOnStop {
                if let problem = prefs.backendProblem {
                    recordingNotes.append("Summaries are off for this recording: \(problem). Fix it in Settings, then use Summarize Now.")
                } else {
                    do { generator = try await makeCheckedGenerator(prefs.backendConfiguration, environment: prefs.environment) } catch {
                        recordingNotes.append("Summaries are off for this recording: \(error.localizedDescription)")
                    }
                }
            }
            do {
                try await session.start()
            } catch {
                self.session = nil
                events?.finish()
                phase = .idle
                notifier.post(title: "Couldn't start recording", body: error.localizedDescription)
                return
            }
            startedAt = Date()
            transcriptStartedAt = startedAt
            phase = .recording
            chime(.start)
            ticker = Task { // cancelled by stop() and discard()
                while !Task.isCancelled {
                    self.now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func handle(_ event: RecordingEvent) {
        switch event {
        case .downloadingSpeechModel: phase = .starting("Downloading the speech model (one time)…")
        case .note(let note): recordingNotes.append(note.prefix(1).uppercased() + note.dropFirst())
        case .started: break
        case .systemAudio(.waiting(let terms)): captureNote = "Waiting for \(terms.joined(separator: ", ")) to play audio…"
        case .systemAudio(.following(let names)):
            if case .excluding = session?.options.scope { captureNote = names.isEmpty ? nil : "Not capturing: \(names.joined(separator: ", "))" }
            else { captureNote = "Capturing: \(names.joined(separator: ", "))" }
        case .systemAudio(.failed(let why)): captureNote = "System audio problem: \(why)"
        case .level(let speaker, let level): levels[speaker] = level
        case .systemAudioSilent:
            systemAudioSilent = true
            notifier.post(title: "The other side isn't being recorded",
                          body: "Something is playing, but Muesli hears silence. Allow Muesli under Screen & System Audio Recording in System Settings.")
        case .segment(let segment):
            let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
            segments.insert(segment, at: index)
        case .stopping: phase = .finishing("Finishing the transcript…")
        case .whisper(.finding(let speaker)): phase = .finishing("Whisper: finding speech (\(speaker.label))…")
        case .whisper(.transcribing(let speaker, let done, let total)): phase = .finishing("Whisper (\(speaker.label)): \(done) of \(total)")
        case .whisper(.noSpeech): break
        case .whisperFailed(let why, _): recordingNotes.append("Whisper failed (\(why)); its audio was kept.")
        case .audioWriteFailed(let why): recordingNotes.append("Couldn't write audio: \(why)")
        }
    }

    func stop(summarize: Bool) {
        guard phase == .recording, let session else { return }
        ticker?.cancel()
        chime(.stop)
        phase = .finishing("Finishing the transcript…")
        let title = title
        Task {
            defer {
                self.session = nil
                events?.finish()
                phase = .idle
                startedAt = nil
                refreshMenuData()
                if quitWhenIdle { NSApp.terminate(nil) }
            }
            let result: RecordingResult
            do { result = try await session.stop() } catch {
                notifier.post(title: "Recording failed", body: error.localizedDescription)
                return
            }
            guard let folder = result.folder else {
                notifier.post(title: "Nothing saved", body: "No speech was recognized.")
                return
            }
            guard summarize, let generator else {
                notifier.post(title: "Transcript saved", body: folder.displayTitle(), session: folder.url)
                return
            }
            await self.summarize(folder: folder, transcript: result.transcript, title: title, generator: generator)
        }
    }

    /// Saves the transcript (no summary, so quitting isn't held up) and quits.
    func stopAndQuit() {
        quitWhenIdle = true
        generator = nil
        stop(summarize: false)
    }

    func discard() {
        guard phase == .recording, let session else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The transcript so far will be deleted. This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ticker?.cancel()
        chime(.stop)
        Task {
            await session.discard()
            self.session = nil
            events?.finish()
            phase = .idle
            startedAt = nil
            transcriptStartedAt = nil
            segments = []
            ask.clear()
        }
    }

    // MARK: Live transcript

    /// The transcript so far (or of the last recording), as the saved file would have it.
    var liveTranscript: Transcript? {
        guard let transcriptStartedAt, !segments.isEmpty else { return nil }
        return Transcript(startedAt: transcriptStartedAt, locale: preferences.locale.identifier, segments: segments)
    }

    /// Everything said so far, with timestamps and times of day, like transcript.md.
    func copyTranscript() {
        guard let transcript = liveTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.markdown(title: title), forType: .string)
        transcriptCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            transcriptCopied = false
        }
    }

    /// Answers stay on this Mac unless Private Cloud Compute is already the
    /// chosen summarizer: a question is never sent anywhere summaries aren't.
    var askKind: AppleGenerator.Kind { preferences.backend == .appleCloud ? .privateCloud : .onDevice }

    /// Why questions can't be asked right now, if the model is the reason.
    var askProblem: String? { AppleGenerator.unavailableReason(askKind) }

    var canAsk: Bool { transcriptStartedAt != nil && !segments.isEmpty && askProblem == nil }

    func askQuestion(_ question: String) {
        guard let transcript = liveTranscript else { return }
        ask.ask(question, transcript: transcript, kind: askKind)
    }

    func retryQuestion(_ exchange: AskModel.Exchange) {
        guard let transcript = liveTranscript else { return }
        ask.retry(exchange, transcript: transcript, kind: askKind)
    }

    // MARK: Sounds

    private enum Chime { case start, stop }

    /// A soft system sound, so you know recording started or stopped without looking.
    private func chime(_ chime: Chime) {
        guard preferences.playSounds else { return }
        let sound = NSSound(named: chime == .start ? "Tink" : "Pop")
        sound?.volume = 0.5
        sound?.play()
    }

    // MARK: Summaries

    /// Summarizes a saved session (after recording, or later from Recent Meetings).
    func summarizeNow(_ url: URL) {
        guard phase == .idle else { return }
        let prefs = preferences
        let folder = SessionFolder(url)
        Task {
            phase = .finishing("Checking \(prefs.backend.menuName)…")
            defer { phase = .idle; refreshMenuData() }
            do {
                let transcript = try folder.loadTranscript()
                let generator = try await makeCheckedGenerator(prefs.backendConfiguration, environment: prefs.environment)
                await summarize(folder: folder, transcript: transcript, title: nil, generator: generator)
            } catch {
                notifier.post(title: "Couldn't summarize", body: error.localizedDescription, session: url)
            }
        }
    }

    private func summarize(folder: SessionFolder, transcript: Transcript, title: String?, generator: any NotesGenerator) async {
        phase = .finishing("Summarizing with \(preferences.backend.menuName)…")
        do {
            let result = try await MuesliSession.summarize(transcript, generator: generator, title: title, saveTo: folder)
            let notes = result.notes
            let count = notes.emailDrafts.count
            if notes.hasProposals { awaitingReview.insert(folder.url) }
            notifier.post(
                title: "Notes ready: \(notes.title)",
                body: count == 0 ? notes.summary : "\(count) email draft\(count == 1 ? "" : "s") to review.",
                session: folder.url, review: notes.hasProposals)
        } catch {
            notifier.post(title: "Summarizing failed", body: "\(error.localizedDescription) The transcript is saved; use Summarize Now to retry.",
                          session: folder.url)
        }
    }

    // MARK: Windows

    func showLiveTranscript() { windows.show(.live, model: self) }
    func showSetup() { windows.show(.setup, model: self) }
    func showSettings() { windows.show(.settings, model: self) }
    func openReview(_ url: URL) {
        awaitingReview.remove(url)
        windows.show(.review(url), model: self)
    }

    func openNotes(_ url: URL) {
        let folder = SessionFolder(url)
        NSWorkspace.shared.open(folder.file(folder.hasNotes ? "notes.md" : "transcript.md"))
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: preferences.outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(preferences.outputRoot)
    }
}

/// One row of Recent Meetings.
struct RecentSession: Identifiable, Hashable {
    let url: URL
    let title: String
    let started: Date?
    let hasNotes: Bool
    let hasProposals: Bool
    var id: URL { url }

    init(_ folder: SessionFolder) {
        url = folder.url
        title = folder.displayTitle()
        started = folder.startedAt()
        let notes = try? folder.loadNotes()
        hasNotes = notes != nil
        hasProposals = notes?.hasProposals ?? false
    }

    var menuTitle: String {
        guard let started else { return title }
        let time = Calendar.current.isDateInToday(started)
            ? started.formatted(date: .omitted, time: .shortened)
            : started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(title) · \(time)"
    }
}

extension Locale {
    var localizedName: String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
}
