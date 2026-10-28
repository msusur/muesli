import Foundation
import FoundationModels
import MuesliCore

/// Answers questions about a meeting as it happens, with Apple Intelligence:
/// on-device, or on Private Cloud Compute (bigger context, so more of a long
/// meeting fits). Each question is answered from a fresh session holding the
/// latest transcript, since the transcript keeps growing between questions.
@available(macOS 26.0, *)
public struct MeetingAssistant: Sendable {
    public enum Update: Sendable {
        /// The part of the transcript the answer is based on. Comes first.
        case excerpt(MeetingQuestions.Excerpt)
        /// The answer so far (the whole text, not a delta).
        case answer(String)
    }

    public let kind: AppleGenerator.Kind

    public init(kind: AppleGenerator.Kind) {
        self.kind = kind
    }

    /// `nil` when the model can be used; otherwise why not and what to do.
    public var unavailableReason: String? { AppleGenerator.unavailableReason(kind) }

    /// Room for an answer of a few short paragraphs.
    static let answerTokens = 600
    /// Earlier questions and answers kept for follow-ups.
    static let historyCharacters = 1_500

    /// How many characters of transcript fit with the instructions, history, question and answer.
    static func transcriptBudget(contextTokens: Int, question: String) -> Int {
        let overheadTokens = (MeetingQuestions.instructions.count + historyCharacters + question.count) / 3 + answerTokens + 200
        return max(1_000, (contextTokens - overheadTokens) * 3)
    }

    public func answer(
        _ question: String, transcript: MuesliCore.Transcript, history: [MeetingQuestions.Exchange]
    ) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = unavailableReason { throw BackendError.unavailable(reason) }
                    let tokens = await AppleGenerator(kind: kind).contextTokens() ?? 4_096
                    let history = MeetingQuestions.recentHistory(history, characterBudget: Self.historyCharacters)
                    var budget = Self.transcriptBudget(contextTokens: tokens, question: question)
                    // The 3-characters-per-token estimate can be off (numbers, other
                    // languages), so a too-long prompt is retried with less transcript.
                    for attempt in 0 ..< 3 {
                        guard let excerpt = MeetingQuestions.excerpt(of: transcript, characterBudget: budget) else {
                            throw BackendError.unavailable("Nothing has been transcribed yet.")
                        }
                        continuation.yield(.excerpt(excerpt))
                        let prompt = MeetingQuestions.prompt(question: question, excerpt: excerpt, history: history)
                        do {
                            try await stream(prompt) { continuation.yield(.answer($0)) }
                            break
                        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where attempt < 2 {
                            budget = budget * 6 / 10
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.explain(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ prompt: String, onText: (String) -> Void) async throws {
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: Self.answerTokens)
        switch kind {
        case .onDevice:
            // Answering from text the user already has is a content transformation;
            // the permissive mode avoids false refusals on ordinary meeting topics.
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: MeetingQuestions.instructions)
            for try await snapshot in session.streamResponse(to: prompt, options: options) { onText(snapshot.content) }
        case .privateCloud:
            guard #available(macOS 27.0, *) else { throw BackendError.unavailable("Private Cloud Compute needs macOS 27 or later.") }
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: MeetingQuestions.instructions)
            for try await snapshot in session.streamResponse(to: prompt, options: options) { onText(snapshot.content) }
        }
    }

    /// Model errors as sentences a person can act on.
    static func explain(_ error: Error) -> Error {
        guard let error = error as? LanguageModelSession.GenerationError else { return error }
        let message = switch error {
        case .exceededContextWindowSize: "The question and transcript are too long for the model. Try a shorter question."
        case .guardrailViolation, .refusal: "Apple's model declined to answer that. Try rephrasing the question."
        case .unsupportedLanguageOrLocale: "Apple's model doesn't support this language yet."
        case .assetsUnavailable: "The model isn't available right now; it may still be downloading."
        case .rateLimited, .concurrentRequests: "The model is busy. Try again in a moment."
        default: error.localizedDescription
        }
        return BackendError.unavailable(message)
    }
}
