import Foundation

public enum BackendError: Error, LocalizedError, Equatable {
    case missingAPIKey(envVar: String)
    case http(status: Int, message: String)
    case refused(category: String?)
    case truncated
    case unavailable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            "No API key. Export \(name) in your shell (muesli never takes keys as command-line arguments)."
        case .http(401, _), .http(403, _):
            "The server rejected the API key. Check it and that it can use this model."
        case .http(429, let m):
            "Rate limited or out of quota. \(m)"
        case .http(let status, let m) where status >= 500:
            "The server is unavailable or overloaded (\(status)). \(m)"
        case .http(let status, let m):
            "The server returned an error (\(status)): \(m)"
        case .refused(let category):
            "The model declined to process this transcript" + (category.map { " (\($0))" } ?? "") + "."
        case .truncated:
            "The model's reply was cut off before the notes were complete."
        case .unavailable(let why): why
        case .badResponse(let why): "Unexpected response from the model server: \(why)"
        }
    }
}

/// POST-JSON with the retry policy the official SDKs use: up to two retries on
/// 408/409/429/5xx and dropped connections, honoring `retry-after`.
struct HTTPClient: Sendable {
    var session: URLSession
    var maxRetries = 2
    var baseDelay: TimeInterval = 0.5

    /// Long-context requests with thinking can legitimately run for minutes, so
    /// the 60 s `URLSession` default is far too short.
    static func makeSession(timeout: TimeInterval = 600) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 1.5
        return URLSession(configuration: configuration)
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse("not an HTTP response") }
                if (200 ..< 300).contains(http.statusCode) { return data }
                if Self.isRetryable(status: http.statusCode), attempt < maxRetries {
                    try await sleep(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "retry-after"))
                    attempt += 1
                    continue
                }
                throw BackendError.http(status: http.statusCode, message: Self.message(in: data))
            } catch let error as URLError where Self.isRetryable(error) && attempt < maxRetries {
                try await sleep(attempt: attempt, retryAfter: nil)
                attempt += 1
            }
        }
    }

    private func sleep(attempt: Int, retryAfter: String?) async throws {
        let seconds = retryAfter.flatMap(TimeInterval.init).map { min($0, 30) } ?? min(baseDelay * pow(2, Double(attempt)), 8)
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }

    static func isRetryable(status: Int) -> Bool { status == 408 || status == 409 || status == 429 || status >= 500 }
    static func isRetryable(_ error: URLError) -> Bool { error.code == .timedOut || error.code == .networkConnectionLost }

    /// Pulls `error.message` out of Anthropic / OpenAI-style error bodies; never
    /// echoes request headers, so a key can't leak into an error message.
    static func message(in data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message, !message.isEmpty {
            return message
        }
        return String(String(decoding: data, as: UTF8.self).prefix(300))
    }
}
