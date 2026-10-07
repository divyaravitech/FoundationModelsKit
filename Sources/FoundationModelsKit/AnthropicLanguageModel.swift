// AnthropicLanguageModel.swift
// URLSession-based backend for the Anthropic Messages API.
// No external dependencies — uses only Foundation.

import Foundation

// MARK: - Configuration

/// API credentials and model selection for the Anthropic backend.
public struct AnthropicConfiguration: Sendable {
    /// Your Anthropic API key (`sk-ant-…`). Never hard-code — inject from
    /// environment variables or a secrets store at app startup.
    public var apiKey: String

    /// Anthropic model ID.
    public var model: String

    /// Maximum tokens the model may generate.
    public var maxTokens: Int

    /// Base URL (override for proxies or test servers).
    public var baseURL: URL

    /// The production Anthropic API endpoint.
    ///
    /// Built from a string literal that is known-valid at compile time, so the
    /// unwrap cannot fail at runtime. Kept in one place so no `!` appears in a
    /// default argument, where it would read as an invitation to pass one.
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    /// Model IDs are complete as published — never append a date suffix.
    /// `claude-opus-5-5-20260401` is not a valid ID and fails at request time.
    public static let defaultModel = "claude-opus-5-5"

    public init(
        apiKey: String,
        model: String = AnthropicConfiguration.defaultModel,
        maxTokens: Int = 1024,
        baseURL: URL = AnthropicConfiguration.defaultBaseURL
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }
}

// Redact the key from `print`, string interpolation, and `po` in the debugger.
// Without this, logging a configuration — or a crash report capturing one —
// exposes a live credential in plain text.
extension AnthropicConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AnthropicConfiguration(model: \(model), maxTokens: \(maxTokens), baseURL: \(baseURL), apiKey: <redacted>)"
    }
    public var debugDescription: String { description }
}

// MARK: - Backend

/// Calls the Anthropic Messages API and maps responses to `LanguageModelProviding`.
///
/// `URLSession` is already thread-safe, so this is a `struct` — no actor overhead.
///
/// ```swift
/// guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
///     throw ConfigError.missingAPIKey   // fail with a clear message, never force-unwrap
/// }
/// let anthropic = AnthropicLanguageModel(config: AnthropicConfiguration(apiKey: apiKey))
/// let response = try await anthropic.sendMessage(
///     request: ModelRequest(content: "Hello!", privacySensitivity: .low)
/// )
/// ```
public struct AnthropicLanguageModel: LanguageModelProviding, Sendable {

    private let config: AnthropicConfiguration
    private let session: URLSession

    public init(config: AnthropicConfiguration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - LanguageModelProviding

    public func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        let urlRequest = try makeRequest(for: request, stream: false)
        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decode(data: data)
    }

    public func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try self.makeRequest(for: request, stream: true)
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    try self.validate(response: response, data: nil)

                    for try await line in bytes.lines {
                        // Cancellation closes the underlying connection rather
                        // than draining a response nobody is reading.
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard
                            let data = payload.data(using: .utf8),
                            let event = try? JSONDecoder().decode(StreamEvent.self, from: data),
                            let text = event.delta?.text
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private helpers

    private func makeRequest(for request: ModelRequest, stream: Bool) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("v1/messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "messages": [["role": "user", "content": request.content]],
        ]
        if stream { body["stream"] = true }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// Status codes worth trying again: rate limiting, and any server-side
    /// fault including Anthropic's 529 "overloaded".
    ///
    /// These map to ``LanguageModelError/unavailable`` so that
    /// ``RetryingLanguageModel`` backs off and retries. Mapping them to
    /// ``AnthropicError/apiError(statusCode:body:)`` instead — as an earlier
    /// version did for everything except 529 — meant a rate-limited request
    /// failed outright rather than being retried.
    /// `internal` rather than `private` so the retry classification is pinned
    /// by tests — it is not part of the public API.
    static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if Self.isTransient(statusCode: http.statusCode) {
                throw LanguageModelError.unavailable
            }
            // 4xx other than 408/429 is a client error — retrying sends the
            // same bad request again, so surface it with the server's detail.
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw AnthropicError.apiError(statusCode: http.statusCode, body: detail)
        }
    }

    private func decode(data: Data) throws -> ModelResponse {
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        let text = decoded.content.first(where: { $0.type == "text" })?.text ?? ""
        return ModelResponse(
            content: text,
            stopReason: decoded.stopReason ?? "end_turn",
            usage: TokenUsage(
                inputTokens: decoded.usage.inputTokens,
                outputTokens: decoded.usage.outputTokens
            )
        )
    }
}

// MARK: - Anthropic-specific error

public enum AnthropicError: LocalizedError {
    case apiError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .apiError(let code, let body):
            return "Anthropic API error \(code): \(body)"
        }
    }
}

// MARK: - Internal response shapes

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
    enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }
}

private struct StreamEvent: Decodable {
    let delta: Delta?
    struct Delta: Decodable {
        let text: String?
    }
}
