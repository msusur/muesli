import Foundation
import MuesliCore
import Testing
@testable import MuesliSummarize

// MARK: - Mock server

/// Intercepts URLSession traffic. Routes by host so suites can run in parallel:
/// each test registers its own unique host and queue of canned responses.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    struct Captured {
        var url: URL
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
    }

    final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Reply]
        private var _requests: [Captured] = []
        init(_ replies: [Reply]) { queue = replies }
        var requests: [Captured] { lock.withLock { _requests } }
        func next(_ captured: Captured) -> Reply {
            lock.withLock {
                _requests.append(captured)
                return queue.count > 1 ? queue.removeFirst() : queue[0] // last reply repeats
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    /// A fresh host + session pair wired to canned replies.
    static func make(_ replies: [Reply]) -> (host: String, url: URL, session: URLSession, route: Route) {
        let host = "mock-\(UUID().uuidString.lowercased()).test"
        let route = Route(replies)
        lock.withLock { routes[host] = route }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return (host, URL(string: "https://\(host)")!, URLSession(configuration: configuration), route)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let route = Self.lock.withLock({ Self.routes[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let reply = route.next(Captured(url: url, headers: headers, body: Self.readBody(request)))
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands the body to protocols as a stream, not `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private let notesJSON = """
{"title":"Launch sync","summary":"Launch moves to Thursday.","keyPoints":["Launch moved"],"decisions":[],
 "actionItems":[{"title":"Send budget","owner":"Me","dueDate":"2026-09-28","dueText":"by Monday","context":""}],
 "events":[],"emailDrafts":[],"openQuestions":[],"enhancedNotes":""}
"""

private func anthropicReply(text: String = notesJSON, stop: String = "end_turn", extra: String = "") -> MockURLProtocol.Reply {
    let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    return .json("""
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5",
     "content":[{"type":"thinking","thinking":"","signature":"sig"},{"type":"text","text":\(escaped)}],
     "stop_reason":"\(stop)","usage":{"input_tokens":1234,"output_tokens":321}\(extra)}
    """)
}

// MARK: - Anthropic

@Suite("Anthropic backend")
struct AnthropicTests {
    @Test("sends a structured-output request with fallbacks on Opus 5")
    func requestShape() async throws {
        let mock = MockURLProtocol.make([anthropicReply()])
        let gen = AnthropicGenerator(apiKey: "fake-test-key-123", baseURL: mock.url, session: mock.session)
        _ = try await gen.generate(system: "SYSTEM", user: "USER")

        let req = try #require(mock.route.requests.first)
        #expect(req.url.path == "/v1/messages")
        #expect(req.headers["x-api-key"] == "fake-test-key-123")
        #expect(req.headers["anthropic-version"] == "2023-06-01")
        #expect(req.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(req.headers["content-type"] == "application/json")

        let body = req.json
        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["max_tokens"] as? Int == 16000)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["system"] as? String == "SYSTEM")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user" && messages[0]["content"] as? String == "USER")

        // Structured outputs carry our schema; sampling params (removed on Opus 5) and prefill are absent.
        let format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect((schema["required"] as? [String])?.first == "title")
        #expect(body["temperature"] == nil && body["top_p"] == nil && body["thinking"] == nil)
    }

    @Test("omits fallbacks for models that don't support them, and when disabled")
    func noFallbacks() async throws {
        for (model, enabled) in [("claude-sonnet-5", true), ("claude-haiku-4-5", true), ("claude-opus-5", false)] {
            let mock = MockURLProtocol.make([anthropicReply()])
            let gen = AnthropicGenerator(apiKey: "k", model: model, baseURL: mock.url, useFallbacks: enabled, session: mock.session)
            _ = try await gen.generate(system: "s", user: "u")
            let req = try #require(mock.route.requests.first)
            #expect(req.json["fallbacks"] == nil, "\(model) enabled=\(enabled)")
            #expect(req.headers["anthropic-beta"] == nil, "\(model) enabled=\(enabled)")
            #expect(req.json["model"] as? String == model)
        }
    }

    @Test("parses notes, skipping thinking blocks, and reports usage")
    func parses() async throws {
        let mock = MockURLProtocol.make([anthropicReply()])
        let gen = AnthropicGenerator(apiKey: "k", baseURL: mock.url, session: mock.session)
        let result = try await gen.generate(system: "s", user: "u")
        #expect(result.notes.title == "Launch sync")
        #expect(result.notes.actionItems.first?.dueDate == "2026-09-28")
        #expect(result.usage == TokenUsage(inputTokens: 1234, outputTokens: 321))
    }

    @Test("a refusal is reported, never parsed")
    func refusal() async {
        let mock = MockURLProtocol.make([anthropicReply(text: "", stop: "refusal", extra: #","stop_details":{"type":"refusal","category":"cyber"}"#)])
        let gen = AnthropicGenerator(apiKey: "k", baseURL: mock.url, session: mock.session)
        await #expect(throws: BackendError.refused(category: "cyber")) { try await gen.generate(system: "s", user: "u") }
    }

    @Test("a max_tokens stop is reported as truncation")
    func truncated() async {
        let mock = MockURLProtocol.make([anthropicReply(text: #"{"title":"cut off"#, stop: "max_tokens")])
        let gen = AnthropicGenerator(apiKey: "k", baseURL: mock.url, session: mock.session)
        await #expect(throws: BackendError.truncated) { try await gen.generate(system: "s", user: "u") }
    }

    @Test("401 surfaces a helpful error that never contains the key")
    func unauthorized() async {
        let mock = MockURLProtocol.make([.json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401)])
        let gen = AnthropicGenerator(apiKey: "fake-secret-value-456", baseURL: mock.url, session: mock.session)
        do {
            _ = try await gen.generate(system: "s", user: "u")
            Issue.record("expected a throw")
        } catch {
            #expect(mock.route.requests.count == 1, "401 must not be retried")
            let text = error.localizedDescription
            #expect(text.contains("API key"))
            #expect(!text.contains("fake-secret-value-456"))
        }
    }

    @Test("retries overloaded responses, honoring the retry budget")
    func retries() async throws {
        let overloaded = MockURLProtocol.Reply.json(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529)
        let ok = anthropicReply()

        let recovers = MockURLProtocol.make([overloaded, overloaded, ok])
        let a = AnthropicGenerator(apiKey: "k", baseURL: recovers.url, session: recovers.session, retryDelay: 0)
        _ = try await a.generate(system: "s", user: "u")
        #expect(recovers.route.requests.count == 3)

        let hopeless = MockURLProtocol.make([overloaded])
        let b = AnthropicGenerator(apiKey: "k", baseURL: hopeless.url, session: hopeless.session, retryDelay: 0)
        await #expect(throws: BackendError.self) { try await b.generate(system: "s", user: "u") }
        #expect(hopeless.route.requests.count == 3) // first try + 2 retries
    }

    @Test("400s are not retried and keep the API's message")
    func badRequest() async {
        let mock = MockURLProtocol.make([.json(#"{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: not supported here"}}"#, status: 400)])
        let gen = AnthropicGenerator(apiKey: "k", baseURL: mock.url, session: mock.session, retryDelay: 0)
        await #expect(throws: BackendError.http(status: 400, message: "fallbacks: not supported here")) {
            try await gen.generate(system: "s", user: "u")
        }
        #expect(mock.route.requests.count == 1)
    }

    @Test("a missing key is a clear error")
    func missingKey() {
        #expect(throws: BackendError.missingAPIKey(envVar: "ANTHROPIC_API_KEY")) {
            try AnthropicGenerator.fromEnvironment(environment: [:])
        }
        #expect(throws: BackendError.missingAPIKey(envVar: "ANTHROPIC_API_KEY")) {
            try AnthropicGenerator.fromEnvironment(environment: ["ANTHROPIC_API_KEY": ""])
        }
    }

    @Test("defaults to Claude Opus 5 and a large transcript budget")
    func defaults() async throws {
        let gen = try AnthropicGenerator.fromEnvironment(environment: ["ANTHROPIC_API_KEY": "k"])
        #expect(gen.model == "claude-opus-5")
        #expect(gen.displayName == "anthropic:claude-opus-5")
        #expect(await gen.transcriptCharacterBudget >= 300_000)
    }
}

// MARK: - OpenAI-compatible

@Suite("OpenAI-compatible backend")
struct OpenAICompatibleTests {
    private func reply(_ content: String, finish: String = "stop") -> MockURLProtocol.Reply {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        return .json(#"{"choices":[{"message":{"role":"assistant","content":\#(escaped)},"finish_reason":"\#(finish)"}],"usage":{"prompt_tokens":900,"completion_tokens":200}}"#)
    }

    @Test("posts to /chat/completions with a strict json_schema and no auth by default")
    func requestShape() async throws {
        let mock = MockURLProtocol.make([reply(notesJSON)])
        let gen = OpenAICompatibleGenerator(baseURL: mock.url.appending(path: "v1"), model: "qwen3:8b", session: mock.session)
        let result = try await gen.generate(system: "SYSTEM", user: "USER")

        let req = try #require(mock.route.requests.first)
        #expect(req.url.path == "/v1/chat/completions")
        #expect(req.headers["authorization"] == nil)
        let body = req.json
        #expect(body["model"] as? String == "qwen3:8b")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let js = try #require(format["json_schema"] as? [String: Any])
        #expect(js["strict"] as? Bool == true && js["name"] as? String == "MeetingNotes")
        #expect((js["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)

        #expect(result.notes.title == "Launch sync")
        #expect(result.usage == TokenUsage(inputTokens: 900, outputTokens: 200))
    }

    @Test("sends a bearer token when configured")
    func bearer() async throws {
        let mock = MockURLProtocol.make([reply(notesJSON)])
        let gen = OpenAICompatibleGenerator(baseURL: mock.url, model: "m", apiKey: "tok", session: mock.session)
        _ = try await gen.generate(system: "s", user: "u")
        #expect(mock.route.requests.first?.headers["authorization"] == "Bearer tok")
    }

    @Test("tolerates fenced or chatty output from models without constrained decoding")
    func fenced() async throws {
        let mock = MockURLProtocol.make([reply("Sure!\n```json\n\(notesJSON)\n```")])
        let gen = OpenAICompatibleGenerator(baseURL: mock.url, model: "m", session: mock.session)
        #expect(try await gen.generate(system: "s", user: "u").notes.title == "Launch sync")
    }

    @Test("length stop and empty content are errors")
    func failures() async {
        let cut = MockURLProtocol.make([reply(#"{"title":"x"#, finish: "length")])
        await #expect(throws: BackendError.truncated) {
            try await OpenAICompatibleGenerator(baseURL: cut.url, model: "m", session: cut.session).generate(system: "s", user: "u")
        }
        let empty = MockURLProtocol.make([.json(#"{"choices":[{"message":{"content":null},"finish_reason":"stop"}]}"#)])
        await #expect(throws: BackendError.self) {
            try await OpenAICompatibleGenerator(baseURL: empty.url, model: "m", session: empty.session).generate(system: "s", user: "u")
        }
    }

    @Test("the transcript budget follows the context window, and tiny windows are rejected")
    func budget() async throws {
        let small = OpenAICompatibleGenerator(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m", contextTokens: 2048)
        await #expect(throws: BackendError.self) { try await small.preflight() }

        let medium = OpenAICompatibleGenerator(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m", contextTokens: 8192)
        try await medium.preflight()
        let large = OpenAICompatibleGenerator(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m", contextTokens: 32768)
        #expect(await large.transcriptCharacterBudget > (await medium.transcriptCharacterBudget) * 3)
        #expect(await medium.transcriptCharacterBudget >= ContextBudget.minimumUseful)
    }
}

// MARK: - Configuration & plumbing

@Suite("Backend configuration")
struct ConfigurationTests {
    @Test("openai needs a URL and a model")
    func openaiRequirements() {
        #expect(throws: BackendError.self) { try BackendConfiguration(backend: .openai, model: "m").makeGenerator(environment: [:]) }
        #expect(throws: BackendError.self) {
            try BackendConfiguration(backend: .openai, baseURL: URL(string: "http://localhost:11434/v1")).makeGenerator(environment: [:])
        }
        #expect(throws: BackendError.missingAPIKey(envVar: "MY_KEY")) {
            try BackendConfiguration(backend: .openai, model: "m", baseURL: URL(string: "http://x/v1"), apiKeyEnvironmentVariable: "MY_KEY")
                .makeGenerator(environment: [:])
        }
    }

    @Test("builds each backend")
    func builds() throws {
        let env = ["ANTHROPIC_API_KEY": "k", "MY_KEY": "t"]
        #expect(try BackendConfiguration(backend: .anthropic).makeGenerator(environment: env).displayName == "anthropic:claude-opus-5")
        #expect(try BackendConfiguration(backend: .anthropic, model: "claude-sonnet-5").makeGenerator(environment: env).displayName == "anthropic:claude-sonnet-5")
        #expect(try BackendConfiguration(backend: .apple).makeGenerator(environment: env).displayName == "apple:on-device")
        #expect(try BackendConfiguration(backend: .appleCloud).makeGenerator(environment: env).displayName == "apple:private-cloud")
        let local = try BackendConfiguration(backend: .openai, model: "qwen", baseURL: URL(string: "http://localhost:11434/v1"), apiKeyEnvironmentVariable: "MY_KEY").makeGenerator(environment: env)
        #expect(local.displayName == "localhost:qwen")
    }

    @Test("the automatic choice is never a network backend")
    func automaticIsLocal() {
        let choice = Backend.automatic()
        #expect(choice == nil || choice == .apple)
    }

    @Test("error bodies from both API styles are unpacked")
    func errorMessages() {
        #expect(HTTPClient.message(in: Data(#"{"type":"error","error":{"message":"anthropic style"}}"#.utf8)) == "anthropic style")
        #expect(HTTPClient.message(in: Data(#"{"error":{"message":"openai style","type":"x"}}"#.utf8)) == "openai style")
        #expect(HTTPClient.message(in: Data("plain text".utf8)) == "plain text")
    }
}
