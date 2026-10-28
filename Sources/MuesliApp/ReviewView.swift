import AppKit
import MuesliActions
import MuesliCore
import MuesliSession
import Observation
import SwiftUI

/// The post-meeting checklist: tick what to add to Reminders, Calendar and Mail.
/// Nothing is created until "Add" is pressed. Replaces `muesli actions`' prompts.
struct ReviewView: View {
    let model: AppModel
    let url: URL
    @Bindable var state: ReviewState

    init(model: AppModel, url: URL) {
        self.model = model
        self.url = url
        state = ReviewState()
    }

    private var notes: MeetingNotes? { state.notes }
    private var plan: ActionPlan? { state.plan }
    private var outcomes: [ActionRunner.Outcome] { state.outcomes }
    private var undoable: Int { state.undoable }
    private var working: Bool { state.working }
    private var loadError: String? { state.loadError }

    private var runner: ActionRunner {
        let prefs = model.preferences
        return ActionRunner(folder: SessionFolder(url), configuration: .init(
            remindersList: prefs.remindersList.isEmpty ? nil : prefs.remindersList,
            calendar: prefs.calendarName.isEmpty ? nil : prefs.calendarName))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                ContentUnavailableView("Can't review this meeting", systemImage: "doc.questionmark", description: Text(loadError))
            } else if let notes, let plan {
                ScrollView { content(notes: notes, plan: plan).padding(16) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 480, minHeight: 400)
        .task { load(selectingDefaults: true) }
    }

    @ViewBuilder private func content(notes: MeetingNotes, plan: ActionPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(notes.title).font(.title2.bold())
                Text(notes.meetingStart.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
            }
            if !notes.summary.isEmpty { Text(notes.summary).textSelection(.enabled) }

            if !outcomes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcomes) { outcome in
                        Label(outcome.error.map { "\(outcome.action.title): \($0)" } ?? "Added “\(outcome.action.title)”",
                              systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                    }
                }
            }

            if plan.actions.isEmpty {
                Text("Nothing new to add.").foregroundStyle(.secondary)
            }
            ForEach(ProposedAction.Kind.allCases, id: \.self) { kind in
                let actions = plan.actions.filter { $0.kind == kind }
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(kind.heading).font(.headline)
                            if kind == .email { Text("opened in your mail app, never sent").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(actions) { action in
                            Toggle(isOn: binding(for: action.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                    if !action.detail.isEmpty { Text(action.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }

            if !plan.skipped.isEmpty {
                DisclosureGroup("Not proposed (\(plan.skipped.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, item in
                            Text("\(item.title): \(item.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !plan.alreadyApplied.isEmpty {
                Text("Already added earlier: \(plan.alreadyApplied.map(\.title).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Open Notes") { model.openNotes(url) }
            if undoable > 0 {
                Button("Undo Added (\(undoable))…") {
                    model.undoActions(url)
                    Task { try? await Task.sleep(for: .seconds(1)); load(selectingDefaults: false) }
                }
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Add \(chosen.count) Selected") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || working)
        }
    }

    private var chosen: [ProposedAction] { plan?.actions.filter { state.selected.contains($0.id) } ?? [] }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { state.selected.contains(id) }, set: { if $0 { state.selected.insert(id) } else { state.selected.remove(id) } })
    }

    private func load(selectingDefaults: Bool) {
        do {
            let (plan, notes) = try runner.plan()
            state.plan = plan
            state.notes = notes
            if selectingDefaults { state.selected = Set(plan.actions.filter(\.selectedByDefault).map(\.id)) }
            state.undoable = runner.undoable().count
        } catch {
            state.loadError = error.localizedDescription
        }
    }

    private func apply() {
        let actions = chosen
        let runner = runner
        state.working = true
        Task {
            state.outcomes = await runner.apply(actions)
            state.working = false
            load(selectingDefaults: true)
            model.refreshMenuData()
        }
    }
}

/// The review window's state. A class rather than `@State`, because SwiftUI's
/// macros ship only with Xcode and muesli builds with the Command Line Tools.
@MainActor @Observable
final class ReviewState {
    var notes: MeetingNotes?
    var plan: ActionPlan?
    var selected: Set<UUID> = []
    var outcomes: [ActionRunner.Outcome] = []
    var undoable = 0
    var working = false
    var loadError: String?
}
