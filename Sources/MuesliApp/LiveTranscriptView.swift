import AppKit
import MuesliCore
import MuesliSession
import SwiftUI

/// The floating panel: what's being heard on each side, the transcript as it
/// forms, and questions about it answered by Apple Intelligence.
struct LiveTranscriptView: View {
    let model: AppModel
    @Bindable var ask: AskModel

    init(model: AppModel) {
        self.model = model
        ask = model.ask
    }

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
            tabBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            switch ask.tab {
            case .transcript: transcript
            case .ask: AskConversationView(model: model, ask: ask)
            }
            Divider()
            AskComposer(model: model, ask: ask)
                .padding(12)
            if model.phase == .recording {
                Divider()
                HStack {
                    Button("Discard…") { model.discard() }
                    Spacer()
                    Button("Stop Without Summary") { model.stop(summarize: false) }
                    // No Return shortcut: Return belongs to the question field, and
                    // shouldn't end a meeting when the field isn't focused.
                    Button("Stop & Summarize") { model.stop(summarize: true) }
                        .disabled(!model.preferences.summarizeOnStop || model.preferences.backendProblem != nil)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 400, minHeight: 460)
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

    private var tabBar: some View {
        HStack {
            Picker("View", selection: $ask.tab) {
                Text("Transcript").tag(AskModel.Tab.transcript)
                Text(ask.exchanges.isEmpty ? "Ask" : "Ask (\(ask.exchanges.count))").tag(AskModel.Tab.ask)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            switch ask.tab {
            case .transcript:
                Button {
                    model.copyTranscript()
                } label: {
                    Label(model.transcriptCopied ? "Copied" : "Copy All",
                          systemImage: model.transcriptCopied ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.segments.isEmpty)
                .help("Copy the whole transcript, with timestamps and times of day")
            case .ask:
                Button {
                    ask.clear()
                    ask.tab = .ask
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(ask.exchanges.isEmpty)
                .help("Start a new conversation")
            }
        }
        .controlSize(.small)
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
            .onAppear { if let last = model.segments.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: model.segments.count) {
                if let last = model.segments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

// MARK: - Ask

/// The questions asked so far and their answers, newest at the bottom.
private struct AskConversationView: View {
    let model: AppModel
    let ask: AskModel

    var body: some View {
        if ask.exchanges.isEmpty {
            AskEmptyState(model: model)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(ask.exchanges) { exchange in
                            ExchangeView(exchange: exchange) { model.retryQuestion(exchange) }
                                .id(exchange.id)
                        }
                        Color.clear.frame(height: 1).id(bottom)
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(bottom, anchor: .bottom) }
                .onChange(of: ask.exchanges.count) { withAnimation { proxy.scrollTo(bottom, anchor: .bottom) } }
                // Follow a streaming answer as it grows.
                .onChange(of: ask.exchanges.last?.answer) { proxy.scrollTo(bottom, anchor: .bottom) }
            }
        }
    }

    private let bottom = "bottom"
}

/// Before the first question: what this is, and some to start with.
private struct AskEmptyState: View {
    let model: AppModel

    private static let suggestions = [
        "Summarize the meeting so far",
        "What has been decided?",
        "What are my action items?",
        "What happened in the last 5 minutes?",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    Text("Ask about this meeting").font(.headline)
                    Text("Answers come from the transcript so far, so they're only as good as what was heard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            model.askQuestion(suggestion)
                        } label: {
                            Label(suggestion, systemImage: "text.bubble")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 300)
                .disabled(!model.canAsk)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One question (right, in a bubble) and its answer (left, as plain text).
private struct ExchangeView: View {
    let exchange: AskModel.Exchange
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                Text(exchange.question)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            answer
        }
    }

    @ViewBuilder private var answer: some View {
        switch exchange.state {
        case .thinking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the transcript…").foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label(why, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry).controlSize(.small)
            }
        case .answering, .done, .stopped:
            VStack(alignment: .leading, spacing: 4) {
                Text(rendered)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                footer
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let coverage { Text(coverage) }
            if exchange.state == .stopped { Text("· Stopped") }
            Spacer()
            if exchange.state == .done {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exchange.answer, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this answer")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Which part of the meeting the answer could see.
    private var coverage: String? {
        guard let excerpt = exchange.excerpt else { return nil }
        let range = "\(Transcript.timestamp(excerpt.from))–\(Transcript.timestamp(excerpt.to))"
        return excerpt.isWholeMeeting ? "Based on \(range)" : "Based on \(range) · earlier parts didn't fit"
    }

    /// Bold, italics and code as the model wrote them; line breaks kept.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: exchange.answer, options: options)) ?? AttributedString(exchange.answer)
    }
}

/// The question field, shown under both tabs.
private struct AskComposer: View {
    let model: AppModel
    @Bindable var ask: AskModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $ask.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 4)
                    .focused($focused)
                    .onSubmit(submit)
                    .disabled(!model.canAsk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3)))
                if ask.isAnswering {
                    Button(action: ask.stop) {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop answering (Esc)")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canSend)
                    .help("Ask (Return)")
                }
            }
            footnote
        }
        .onChange(of: ask.tab) { _, tab in if tab == .ask { focused = true } }
    }

    private var canSend: Bool {
        model.canAsk && !ask.isAnswering && !ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        model.segments.isEmpty ? "Ask once something has been said…" : "Ask about this meeting…"
    }

    @ViewBuilder private var footnote: some View {
        if let problem = model.askProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(model.askKind == .privateCloud
                ? "Answered by Apple Intelligence on Private Cloud Compute, your summarizer."
                : "Answered by Apple Intelligence on this Mac. Nothing leaves it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func submit() {
        guard canSend else { return }
        model.askQuestion(ask.draft)
        focused = true
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
