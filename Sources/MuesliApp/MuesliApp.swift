import AppKit
import MuesliCore
import MuesliSession
import MuesliSummarize
import SwiftUI

@main
struct MuesliMenuBarApp: App {
    // Not `@State`: SwiftUI's macros ship only with Xcode, and the App value is created once anyway.
    private let model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, preferences: model.preferences)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The icon in the menu bar: a waveform when idle (with a badge when notes are
/// waiting for review), a record dot and the elapsed time while recording, an
/// hourglass while finishing.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .recording:
            Image(systemName: "record.circle.fill")
            Text(formatElapsed(model.elapsed))
        case .starting, .finishing:
            Image(systemName: "hourglass")
        case .idle:
            Image(systemName: model.awaitingReview.isEmpty ? "waveform" : "waveform.badge.exclamationmark")
        }
    }
}

func formatElapsed(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct MenuContent: View {
    let model: AppModel
    @Bindable var preferences: Preferences

    var body: some View {
        switch model.phase {
        case .idle: idle
        case .recording: recording
        case .starting(let status), .finishing(let status):
            Text(status)
            Button("Show Live Transcript") { model.showLiveTranscript() }
        }
        Divider()
        meetings
        Divider()
        options
        Divider()
        Button("Check Setup…") { model.showSetup() }
        Button("Settings…") { model.showSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Muesli") { quit() }.keyboardShortcut("q")
    }

    // MARK: Idle

    @ViewBuilder private var idle: some View {
        if let meeting = model.upcoming {
            Button("Record “\(meeting.title)”") { model.start(title: meeting.title) }
                .disabled(!model.canStart)
            Text("    \(meeting.when)")
        }
        Button("Start Recording") { model.start() }
            .keyboardShortcut("r")
            .disabled(!model.canStart)
        Menu("Record From") {
            Picker("System Audio", selection: Bindable(model).source) {
                Text("All System Audio").tag(SystemSource.everything)
                ForEach(appChoices, id: \.self) { name in
                    Text(model.playingApps.contains(name) ? "\(name)  (playing now)" : name).tag(SystemSource.app(name))
                }
                Text("No System Audio").tag(SystemSource.none)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Microphone", isOn: $preferences.useMicrophone)
        }
        if !model.awaitingReview.isEmpty {
            ForEach(model.recent.filter { model.awaitingReview.contains($0.url) }) { session in
                Button("Review “\(session.title)”…") { model.openReview(session.url) }
            }
        }
    }

    /// Apps playing now, plus the chosen one if it has gone quiet, so the check mark doesn't vanish.
    private var appChoices: [String] {
        var apps = model.playingApps
        if case .app(let chosen) = model.source, !apps.contains(chosen) { apps.insert(chosen, at: 0) }
        return apps
    }

    // MARK: Recording

    @ViewBuilder private var recording: some View {
        Text("Recording · \(formatElapsed(model.elapsed)) · \(model.sourceDescription)")
        if model.systemAudioSilent {
            Button("⚠︎ The other side is silent: allow System Audio Recording…") {
                NSWorkspace.shared.open(SetupChecks.Pane.systemAudio.url)
            }
        }
        Button("Show Live Transcript") { model.showLiveTranscript() }.keyboardShortcut("t")
        Divider()
        Button("Stop & Summarize") { model.stop(summarize: true) }
            .keyboardShortcut("s")
            .disabled(!preferences.summarizeOnStop || preferences.backendProblem != nil)
        Button("Stop Without Summary") { model.stop(summarize: false) }
        Button("Discard Recording…") { model.discard() }
    }

    // MARK: Meetings

    @ViewBuilder private var meetings: some View {
        Menu("Recent Meetings") {
            if model.recent.isEmpty { Text("No meetings yet") }
            ForEach(model.recent) { session in
                Menu(session.menuTitle) {
                    Button(session.hasNotes ? "Open Notes" : "Open Transcript") { model.openNotes(session.url) }
                    if session.hasProposals { Button("Review Actions…") { model.openReview(session.url) } }
                    if !session.hasNotes {
                        Button("Summarize Now") { model.summarizeNow(session.url) }.disabled(model.phase.isBusy)
                    }
                    if session.canUndo { Button("Undo Added Items…") { model.undoActions(session.url) } }
                    Divider()
                    Button("Show in Finder") { model.reveal(session.url) }
                }
            }
        }
        Button("Open Muesli Folder") { model.openOutputFolder() }
    }

    // MARK: Options

    @ViewBuilder private var options: some View {
        Picker("Summarize With", selection: $preferences.backend) {
            ForEach(Backend.allCases, id: \.self) { Text($0.menuName).tag($0) }
        }
        if let problem = preferences.backendProblem {
            Button("⚠︎ \(preferences.backend.menuName): \(problem). Settings…") { model.showSettings() }
        }
        Picker("Speech Engine", selection: $preferences.engine) {
            ForEach(Engine.allCases, id: \.self) { engine in
                Text(engine.usesWhisper && !model.whisperAvailable ? "\(engine.displayName) (not installed)" : engine.displayName).tag(engine)
            }
        }
        Menu("Language") {
            Picker("Language", selection: $preferences.localeIdentifier) {
                Text("System (\(Locale.current.localizedName))").tag(String?.none)
                ForEach(model.supportedLocales, id: \.identifier) { Text($0.localizedName).tag(String?.some($0.identifier)) }
            }
            .pickerStyle(.inline)
        }
        Toggle("Summarize When Stopped", isOn: $preferences.summarizeOnStop)
    }

    private func quit() {
        guard model.phase == .recording else { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Stop it and save the transcript before quitting?"
        alert.addButton(withTitle: "Save & Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.stopAndQuit()
    }
}
