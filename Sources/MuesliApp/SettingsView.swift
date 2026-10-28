import AppKit
import MuesliSession
import MuesliSummarize
import ServiceManagement
import Observation
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    // Held here, by the window's root view, which is created once; tabs may be rebuilt.
    let drafts = KeyDrafts()
    let login = LoginItemState()

    var body: some View {
        TabView {
            GeneralSettings(model: model, preferences: preferences, login: login).tabItem { Label("General", systemImage: "gearshape") }
            SummarySettings(preferences: preferences, drafts: drafts).tabItem { Label("Summaries", systemImage: "text.badge.star") }
            SpeechSettings(model: model, preferences: preferences).tabItem { Label("Speech", systemImage: "waveform") }
            ActionSettings(preferences: preferences).tabItem { Label("Actions", systemImage: "checklist") }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 380)
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    let login: LoginItemState

    var body: some View {
        Form {
            LabeledContent("Save meetings in") {
                HStack {
                    TextField("", text: $preferences.outputFolder).labelsHidden()
                    Button("Choose…") { chooseFolder() }
                }
            }
            TextField("Never capture these apps", text: $preferences.excludedApps, prompt: Text("e.g. Music, Spotify"))
            Text("When recording all system audio. Comma-separated names or bundle ids.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Summarize when a recording stops", isOn: $preferences.summarizeOnStop)
            Toggle("Play a soft sound when recording starts and stops", isOn: $preferences.playSounds)
            Toggle("Suggest the current meeting from Calendar", isOn: $preferences.suggestFromCalendar)
                .onChange(of: preferences.suggestFromCalendar) { _, on in
                    guard on else { return }
                    Task {
                        if !(await UpcomingMeeting.requestAccess()) { preferences.suggestFromCalendar = false }
                        model.refreshMenuData(includingRecent: false)
                    }
                }
            Toggle("Open Muesli at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
            if let error = login.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.outputRoot
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            preferences.outputFolder = url.path
            model.refreshMenuData()
        }
    }
}

private struct SummarySettings: View {
    @Bindable var preferences: Preferences
    @Bindable var drafts: KeyDrafts

    var body: some View {
        Form {
            Picker("Summarize with", selection: $preferences.backend) {
                ForEach(Backend.allCases, id: \.self) { Text($0.menuName).tag($0) }
            }
            if let notice = disclosure(for: preferences.backend, baseURL: URL(string: preferences.openAIBaseURL)) {
                Text("Note: \(notice)").font(.caption).foregroundStyle(.secondary)
            }
            if let problem = preferences.backendProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            switch preferences.backend {
            case .apple, .appleCloud:
                Text("Apple's models need no setup. On-device keeps everything on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            case .anthropic:
                keyField("API key", saved: preferences.anthropicKey, draft: $drafts.anthropic) { preferences.anthropicKey = $0 }
                TextField("Model", text: $preferences.anthropicModel, prompt: Text(AnthropicGenerator.defaultModel))
            case .openai:
                TextField("Server URL", text: $preferences.openAIBaseURL, prompt: Text("http://localhost:11434/v1"))
                TextField("Model", text: $preferences.openAIModel, prompt: Text("e.g. llama3.1:8b"))
                TextField("Context window (tokens)", value: $preferences.openAIContextTokens, format: .number)
                keyField("API key (optional)", saved: preferences.openAIKey, draft: $drafts.openAI) { preferences.openAIKey = $0 }
            }
        }
        .formStyle(.grouped)
    }

    /// Keys are saved to the Keychain on "Save", not on every keystroke.
    private func keyField(_ label: String, saved: String, draft: Binding<String>, save: @escaping (String) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                SecureField("", text: draft, prompt: Text(saved.isEmpty ? "not set" : "saved in Keychain")).labelsHidden()
                Button("Save") { save(draft.wrappedValue); draft.wrappedValue = "" }.disabled(draft.wrappedValue.isEmpty)
                if !saved.isEmpty { Button("Remove") { save("") } }
            }
        }
    }
}

private struct SpeechSettings: View {
    let model: AppModel
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Picker("Speech engine", selection: $preferences.engine) {
                ForEach(Engine.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if preferences.engine.usesWhisper && !model.whisperAvailable {
                Text("Whisper isn't installed: run `python3 -m pip install mlx-whisper`, then restart Muesli. Until then Apple's engine is used.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Language", selection: $preferences.localeIdentifier) {
                Text("System (\(Locale.current.localizedName))").tag(String?.none)
                ForEach(model.supportedLocales, id: \.identifier) { Text($0.localizedName).tag(String?.some($0.identifier)) }
            }
            Section("Whisper") {
                TextField("Model", text: $preferences.whisperModel)
                TextField("Python", text: $preferences.pythonPath, prompt: Text("found automatically"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActionSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            TextField("Reminders list", text: $preferences.remindersList, prompt: Text("your default list"))
            TextField("Calendar", text: $preferences.calendarName, prompt: Text("your default calendar"))
            Text("Nothing is added until you press Add in the review window, and anything added can be undone from Recent Meetings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// Not `@State`: SwiftUI's macros ship only with Xcode.

/// API keys being typed, saved to the Keychain only on "Save".
@MainActor @Observable
final class KeyDrafts {
    var anthropic = ""
    var openAI = ""
}

@MainActor @Observable
final class LoginItemState {
    private(set) var enabled = SMAppService.mainApp.status == .enabled
    private(set) var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
