import Foundation
import MuesliCore

/// Claude via the Messages API, over raw HTTP (there is no official Swift SDK).
///
/// Uses structured outputs (`output_config.format` with a JSON Schema) so the
/// reply is guaranteed to match `NotesSchema`.
public struct AnthropicGenerator: NotesGenerator {
    public static let defaultModel = "claude-opus-5"
    public static let apiKeyEnvironmentVariable = "ANTHROPIC_API_KEY"
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let model: String
    private let apiKey: String
    private let endpoint: URL
    private let fallbacksEnabled: Bool
    private let http: HTTPClient

    /// - Parameter useFallbacks: On Opus 5 and Fable 5 a safety classifier can
    ///   occasionally decline benign content. With this on (the default) the API
    ///   re-runs a declined request on Anthropic's recommended fallback model
    ///   instead of failing. Ignored for models that don't support it.
    public init(
        apiKey: String,
        model: String = AnthropicGenerator.defaultModel,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        useFallbacks: Bool = true,
        session: URLSession? = nil,
        retryDelay: TimeInterval = 0.5
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = baseURL.appending(path: "v1/messages")
        self.fallbacksEnabled = useFallbacks && Self.supportsFallbacks(model)
        self.http = HTTPClient(session: session ?? HTTPClient.makeSession(), baseDelay: retryDelay)
    }

    public static func fromEnvironment(
        model: String = defaultModel, useFallbacks: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AnthropicGenerator {
        guard let key = environment[apiKeyEnvironmentVariable], !key.isEmpty else {
            throw BackendError.missingAPIKey(envVar: apiKeyEnvironmentVariable)
        }
        return AnthropicGenerator(apiKey: key, model: model, useFallbacks: useFallbacks)
    }

    static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5")
    }

    public var displayName: String { "anthropic:\(model)" }

    /// Every current Claude model has at least a 200K-token window; 500K
    /// characters is roughly 125K tokens of English speech, leaving headroom.
    public var transcriptCharacterBudget: Int { get async { 500_000 } }

    public func generate(system: String, user: String) async throws -> GenerationResult {
        var headers = [
            "content-type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
        ]
        if fallbacksEnabled { headers["anthropic-beta"] = Self.fallbackBeta }

        let data = try await http.post(endpoint, headers: headers, body: requestBody(system: system, user: user))
        return try Self.parse(data)
    }

    // MARK: Wire format

    func requestBody(system: String, user: String) -> Data {
        var members: [JSONValue.Member] = [
            .init("model", .string(model)),
            // Not streaming: the reply is a few thousand tokens at most, so this
            // stays well under request timeouts.
            .init("max_tokens", .int(16000)),
        ]
        if fallbacksEnabled { members.append(.init("fallbacks", .string("default"))) }
        members += [
            .init("system", .string(system)),
            .init("messages", .array([.object(["role": .string("user"), "content": .string(user)])])),
            .init("output_config", .object(["format": .object([
                "type": .string("json_schema"),
                "schema": NotesSchema.jsonSchema(),
            ])])),
        ]
        return JSONValue.object(members).data()
    }

    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct Usage: Decodable { let inputTokens: Int?; let outputTokens: Int? }
        struct StopDetails: Decodable { let category: String? }
        let content: [Block]
        let stopReason: String?
        let stopDetails: StopDetails?
        let usage: Usage?
    }

    static func parse(_ data: Data) throws -> GenerationResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: Response
        do { response = try decoder.decode(Response.self, from: data) } catch {
            throw BackendError.badResponse(String(String(decoding: data, as: UTF8.self).prefix(200)))
        }

        // Check the stop reason before reading content: a refusal can arrive as
        // a normal 200 with empty or partial content.
        switch response.stopReason {
        case "refusal": throw BackendError.refused(category: response.stopDetails?.category)
        case "max_tokens": throw BackendError.truncated
        default: break
        }

        // Thinking (and, after a fallback, "fallback") blocks aren't the answer.
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        let usage = TokenUsage(inputTokens: response.usage?.inputTokens ?? 0, outputTokens: response.usage?.outputTokens ?? 0)
        return GenerationResult(notes: try GeneratedNotes.parse(text), usage: usage)
    }
}
