import AppKit
import MuesliCore
import MuesliSession
import SwiftUI

/// The floating panel: what's being heard on each side, and the transcript as it forms.
struct LiveTranscriptView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)
            if !banners.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(banners, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if model.systemAudioSilent { silentWarning }
            Divider()
            transcript
            if model.phase == .recording {
                Divider()
                HStack {
                    Button("Discard…") { model.discard() }
                    Spacer()
                    Button("Stop Without Summary") { model.stop(summarize: false) }
                    Button("Stop & Summarize") { model.stop(summarize: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.preferences.summarizeOnStop || model.preferences.backendProblem != nil)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 380, minHeight: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(model.phase == .recording ? Color.red : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(status).font(.headline)
                Spacer()
                if model.phase == .recording {
                    Text(formatElapsed(model.elapsed)).font(.headline.monospacedDigit())
                }
            }
            if model.phase == .recording {
                if model.preferences.useMicrophone { LevelMeter(label: "Me", level: model.levels[.me]) }
                if model.source != .none { LevelMeter(label: "Them", level: model.levels[.them]) }
            }
        }
    }

    private var status: String {
        switch model.phase {
        case .idle: model.segments.isEmpty ? "Not recording" : "Last recording"
        case .recording: model.title.map { "Recording “\($0)”" } ?? "Recording · \(model.sourceDescription)"
        case .starting(let s), .finishing(let s): s
        }
    }

    private var banners: [String] {
        [model.captureNote].compactMap { $0 } + model.recordingNotes
    }

    private var silentWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("The other side isn't being recorded").font(.callout.bold())
                Text("Something is playing, but Muesli hears silence. Allow Muesli under Screen & System Audio Recording, then start a new recording.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { NSWorkspace.shared.open(SetupChecks.Pane.systemAudio.url) }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.segments.isEmpty {
                        Text(model.phase == .recording ? "Listening… lines appear here as they're recognized." : "Nothing yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(model.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Transcript.timestamp(segment.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.speaker.label)
                                .font(.caption.bold())
                                .foregroundStyle(segment.speaker == .me ? Color.accentColor : Color.orange)
                                .frame(width: 40, alignment: .leading)
                            Text(segment.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(segment.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.segments.count) {
                if let last = model.segments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

/// A horizontal peak meter on a -60…0 dBFS scale.
struct LevelMeter: View {
    let label: String
    /// Peak amplitude, 0…1. `nil` before any audio has arrived.
    let level: Float?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.bold()).frame(width: 40, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fraction > 0.9 ? Color.red : fraction > 0.7 ? Color.yellow : Color.green)
                        .frame(width: geometry.size.width * fraction)
                        .animation(.linear(duration: 0.1), value: fraction)
                }
            }
            .frame(height: 6)
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }

    private var fraction: CGFloat {
        guard let level, level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    private var caption: String {
        guard let level else { return "no audio" }
        guard level > 0 else { return "silent" }
        return "\(Int(20 * log10(Double(level)))) dB"
    }
}
