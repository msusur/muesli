import Foundation
import MuesliCore

/// The ways muesli can turn a transcript into notes, as named on the command line.
public enum Backend: String, CaseIterable, Sendable {
    /// Apple's on-device model. Free and never leaves the Mac.
    case apple
    /// Apple's larger model on Private Cloud Compute (macOS 27+). Free within
    /// Apple's quota; the transcript text leaves the Mac, under Apple's
    /// stateless-processing guarantees.
    case appleCloud = "apple-cloud"
    /// Claude, using your own API key. Pay per use.
    case anthropic
    /// Any OpenAI-compatible server: llama.cpp, Ollama, LM Studio, vLLM.
    case openai

    /// The default when the user doesn't choose: the on-device model if it's
    /// ready. Never a network backend: sending a transcript anywhere must be an
    /// explicit choice.
    public static func automatic() -> Backend? {
        AppleGenerator.unavailableReason(.onDevice) == nil ? .apple : nil
    }

    public var summary: String {
        switch self {
        case .apple: "Apple on-device model (free, private)"
        case .appleCloud: "Apple Private Cloud Compute (free within quota)"
        case .anthropic: "Claude API (your key, pay per use)"
        case .openai: "OpenAI-compatible server: llama.cpp, Ollama, LM Studio…"
        }
    }
}

public struct BackendConfiguration: Sendable {
    public var backend: Backend
    /// Model name. Defaults per backend: Claude's default model; required for `openai`.
    public var model: String?
    /// `openai` only. e.g. `http://localhost:11434/v1`.
    public var baseURL: URL?
    /// `openai` only. Name of an environment variable holding a bearer token, if the server needs one.
    public var apiKeyEnvironmentVariable: String?
    /// `openai` only. The server's real context window.
    public var contextTokens: Int?
    /// `anthropic` only. Opt out of server-side refusal fallbacks.
    public var useFallbacks: Bool

    public init(
        backend: Backend, model: String? = nil, baseURL: URL? = nil, apiKeyEnvironmentVariable: String? = nil,
        contextTokens: Int? = nil, useFallbacks: Bool = true
    ) {
        self.backend = backend
        self.model = model
        self.baseURL = baseURL
        self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
        self.contextTokens = contextTokens
        self.useFallbacks = useFallbacks
    }

    public func makeGenerator(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> any NotesGenerator {
        switch backend {
        case .apple:
            return AppleGenerator(kind: .onDevice)
        case .appleCloud:
            return AppleGenerator(kind: .privateCloud)
        case .anthropic:
            return try AnthropicGenerator.fromEnvironment(
                model: model ?? AnthropicGenerator.defaultModel, useFallbacks: useFallbacks, environment: environment)
        case .openai:
            guard let baseURL else {
                throw BackendError.unavailable("--backend openai needs --base-url, e.g. http://localhost:11434/v1 for Ollama.")
            }
            guard let model else {
                throw BackendError.unavailable("--backend openai needs --model, the name of the model your server should use.")
            }
            let key = apiKeyEnvironmentVariable.flatMap { environment[$0] }
            if let name = apiKeyEnvironmentVariable, key == nil {
                throw BackendError.missingAPIKey(envVar: name)
            }
            return OpenAICompatibleGenerator(baseURL: baseURL, model: model, apiKey: key, contextTokens: contextTokens ?? 8192)
        }
    }
}
