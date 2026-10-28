import AppKit
import MuesliSession
import MuesliTranscribe
import Observation
import SwiftUI

/// `muesli doctor`, as a window with buttons that open the right System Settings pane.
struct SetupView: View {
    let model: AppModel
    @Bindable var state = SetupState()

    private var checks: [SetupCheck] { state.checks }
    private var running: Bool { state.running }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(SetupCheck.Section.allCases, id: \.self) { section in
                    let rows = checks.filter { $0.section == section }
                    if !rows.isEmpty {
                        Section(section.rawValue) {
                            ForEach(rows) { row($0) }
                        }
                    }
                }
            }
            .overlay { if checks.isEmpty { ProgressView("Checking…") } }
            Divider()
            HStack {
                Text("Permissions belong to Muesli itself, separately from your terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { Task { await run() } }.disabled(running)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 400)
        .task { await run() }
    }

    private func row(_ check: SetupCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(check.status)).foregroundStyle(color(check.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let url = check.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ status: SetupCheck.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .problem: "xmark.octagon.fill"
        }
    }

    private func color(_ status: SetupCheck.Status) -> Color {
        switch status {
        case .ok: .green
        case .info: .secondary
        case .problem: .red
        }
    }

    private func run() async {
        state.running = true
        let prefs = model.preferences
        state.checks = await SetupChecks.run(
            grantee: "Muesli", environment: prefs.environment, locale: prefs.locale,
            whisper: WhisperConfiguration(model: prefs.whisperModel, python: prefs.pythonPath.isEmpty ? nil : prefs.pythonPath))
        state.running = false
    }
}

/// Not `@State`: SwiftUI's macros ship only with Xcode.
@MainActor @Observable
final class SetupState {
    var checks: [SetupCheck] = []
    var running = false
}
