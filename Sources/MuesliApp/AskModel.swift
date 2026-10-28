import Foundation
import MuesliCore
import MuesliSummarize
import Observation

/// The conversation in the live panel's Ask tab: questions about the meeting,
/// answered from the transcript as it stands when each is asked.
@MainActor @Observable
final class AskModel {
    enum Tab: Hashable { case transcript, ask }

    struct Exchange: Identifiable {
        enum State: Equatable {
            /// Waiting for the first words.
            case thinking
            case answering
            case done
            case stopped
            case failed(String)
        }

        let id = UUID()
        let question: String
        var answer = ""
        var state = State.thinking
        /// Which part of the transcript the answer is based on.
        var excerpt: MeetingQuestions.Excerpt?
    }

    var tab = Tab.transcript
    /// What's being typed in the composer.
    var draft = ""
    private(set) var exchanges: [Exchange] = []
    private(set) var isAnswering = false

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The exchange `task` is answering, so a cancelled task finishing late
    /// doesn't clear a newer one.
    @ObservationIgnored private var answeringID: UUID?

    func ask(_ question: String, transcript: Transcript, kind: AppleGenerator.Kind) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, task == nil else { return }
        let history = exchanges.compactMap { $0.state == .done ? MeetingQuestions.Exchange(question: $0.question, answer: $0.answer) : nil }
        exchanges.append(Exchange(question: question))
        let id = exchanges[exchanges.count - 1].id
        draft = ""
        tab = .ask
        answeringID = id
        isAnswering = true

        task = Task {
            defer {
                if answeringID == id {
                    task = nil
                    answeringID = nil
                    isAnswering = false
                }
            }
            do {
                for try await update in MeetingAssistant(kind: kind).answer(question, transcript: transcript, history: history) {
                    self.update(id) { exchange in
                        switch update {
                        case .excerpt(let excerpt): exchange.excerpt = excerpt
                        case .answer(let text):
                            exchange.answer = text
                            exchange.state = .answering
                        }
                    }
                }
                self.update(id) { exchange in
                    let empty = exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    exchange.state = Task.isCancelled ? .stopped : empty ? .failed("No answer came back. Try asking another way.") : .done
                }
            } catch {
                self.update(id) { $0.state = Task.isCancelled || error is CancellationError ? .stopped : .failed(error.localizedDescription) }
            }
        }
    }

    /// Asks a failed question again, in place of the failed attempt.
    func retry(_ exchange: Exchange, transcript: Transcript, kind: AppleGenerator.Kind) {
        guard task == nil else { return }
        exchanges.removeAll { $0.id == exchange.id }
        ask(exchange.question, transcript: transcript, kind: kind)
    }

    func stop() {
        task?.cancel()
    }

    /// Forgets the conversation, e.g. when a new recording starts.
    func clear() {
        task?.cancel()
        task = nil
        answeringID = nil
        isAnswering = false
        exchanges = []
        draft = ""
        tab = .transcript
    }

    private func update(_ id: UUID, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }
}
