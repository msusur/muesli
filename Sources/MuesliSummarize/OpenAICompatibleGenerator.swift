import Foundation
import MuesliCore

/// Any server that speaks the OpenAI chat-completions protocol: llama.cpp's
/// `llama-server`, Ollama (`http://localhost:11434/v1`), LM Studio, vLLM, and so
/// on. This is the "local model" backend, and it's how muesli runs fully
/// offline without depending on Apple Intelligence.
///
/// Uses `response_format: json_schema`, which llama.cpp and Ollama enforce with
/// constrained decoding, so even small models return well-formed notes.
public struct OpenAICompatibleGenerator: NotesGenerator {
    public let baseURL: URL
    public let model: String
    private let apiKey: String?
    private let contextTokens: Int
    private let http: HTTPClient

    /// - Parameter contextTokens: The server's *actual* context window. Ollama
    ///   defaults to a small one and silently truncates longer prompts, so
    ///   don't set this above what the server really uses.
    public init(
        baseURL: URL, model: String, apiKey: String? = nil, contextTokens: Int = 8192,
        session: URLSession? = nil, retryDelay: TimeInterval = 0.5
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.contextTokens = contextTokens
        self.http = HTTPClient(session: session ?? HTTPClient.makeSession(), baseDelay: retryDelay)
    }

    public var displayName: String { "\(baseURL.host() ?? "server"):\(model)" }

    public var transcriptCharacterBudget: Int {
        get async { ContextBudget.characters(contextTokens: contextTokens) }
    }

    public func preflight() async throws {
        if ContextBudget.characters(contextTokens: contextTokens) < ContextBudget.minimumUseful {
            throw BackendError.unavailable(
                "A context window of \(contextTokens) tokens is too small for muesli's notes format (it needs roughly \(ContextBudget.overheadTokens + 1_000)). Use a larger --context-tokens, or a bigger model.")
        }
    }

    public func generate(system: String, user: String) async throws -> GenerationResult {
        var headers = ["content-type": "application/json"]
        if let apiKey { headers["authorization"] = "Bearer \(apiKey)" }
        let data = try await http.post(baseURL.appending(path: "chat/completions"), headers: headers, body: requestBody(system: system, user: user))
        return try Self.parse(data)
    }

    func requestBody(system: String, user: String) -> Data {
        JSONValue.object([
            "model": .string(model),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .string(user)]),
            ]),
            // Extraction, not creative writing.
            "temperature": .int(0),
            "stream": .bool(false),
            "response_format": .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string(NotesSchema.name),
                    "strict": .bool(true),
                    "schema": NotesSchema.jsonSchema(),
                ]),
            ]),
        ]).data()
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let finishReason: String?
        }
        struct Usage: Decodable { let promptTokens: Int?; let completionTokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }

    static func parse(_ data: Data) throws -> GenerationResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: Response
        do { response = try decoder.decode(Response.self, from: data) } catch {
            throw BackendError.badResponse(String(String(decoding: data, as: UTF8.self).prefix(200)))
        }
        guard let choice = response.choices.first, let content = choice.message?.content else {
            throw BackendError.badResponse("no message content")
        }
        if choice.finishReason == "length" { throw BackendError.truncated }
        let usage = TokenUsage(inputTokens: response.usage?.promptTokens ?? 0, outputTokens: response.usage?.completionTokens ?? 0)
        return GenerationResult(notes: try GeneratedNotes.parse(content), usage: usage)
    }
}

/// Turns a model's context window into how much transcript fits in a request.
public enum ContextBudget {
    /// Tokens spent before any transcript: the system prompt, the meeting
    /// header and calendar, the JSON schema (which some backends put in the
    /// prompt), and room for the reply.
    public static var overheadTokens: Int {
        let promptCharacters = Prompts.system.count + NotesSchema.jsonSchema().serialized().count + 1_200
        return promptCharacters / 3 + 1_500
    }

    /// Below this a request can't hold even a couple of minutes of speech.
    public static let minimumUseful = 4_000

    /// Conservative: about 3 characters per token, which also covers speech with
    /// numbers and names, and slightly worse for other languages.
    public static func characters(contextTokens: Int) -> Int {
        max(0, (contextTokens - overheadTokens) * 3)
    }
}
