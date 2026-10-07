import Foundation

/// Credentials and model selection for the OpenAI backend.
public struct OpenAIConfiguration: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var baseURL: URL

    public static let defaultBaseURL = URL(string: "https://api.openai.com")!
    public static let defaultModel = "gpt-4o"

    public init(
        apiKey: String,
        model: String = OpenAIConfiguration.defaultModel,
        maxTokens: Int = 1024,
        baseURL: URL = OpenAIConfiguration.defaultBaseURL
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }
}

extension OpenAIConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OpenAIConfiguration(model: \(model), maxTokens: \(maxTokens), baseURL: \(baseURL), apiKey: <redacted>)"
    }
    public var debugDescription: String { description }
}

/// Calls the OpenAI Chat Completions API.
///
/// ```swift
/// guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
///     throw ConfigError.missingAPIKey
/// }
/// let openAI = OpenAILanguageModel(config: OpenAIConfiguration(apiKey: key))
/// ```
public struct OpenAILanguageModel: LanguageModelProviding, Sendable {

    private let config: OpenAIConfiguration
    private let session: URLSession

    public init(config: OpenAIConfiguration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

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
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard
                            let data = payload.data(using: .utf8),
                            let event = try? JSONDecoder().decode(StreamChunk.self, from: data),
                            let text = event.choices.first?.delta.content
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    private func makeRequest(for request: ModelRequest, stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": config.model,
            "max_completion_tokens": config.maxTokens,
            "messages": [["role": "user", "content": request.content]],
        ]
        if stream { body["stream"] = true }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if Self.isTransient(statusCode: http.statusCode) {
                throw LanguageModelError.unavailable
            }
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw OpenAIError.apiError(statusCode: http.statusCode, body: detail)
        }
    }

    private func decode(data: Data) throws -> ModelResponse {
        let decoded = try JSONDecoder().decode(CompletionsResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw OpenAIError.apiError(statusCode: 200, body: "response contained no choices")
        }
        return ModelResponse(
            content: choice.message.content ?? "",
            stopReason: choice.finishReason ?? "stop",
            usage: TokenUsage(
                inputTokens: decoded.usage?.promptTokens ?? 0,
                outputTokens: decoded.usage?.completionTokens ?? 0
            )
        )
    }
}

public enum OpenAIError: LocalizedError, Equatable {
    case apiError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .apiError(let code, let body):
            return "OpenAI API error \(code): \(body)"
        }
    }
}

private struct CompletionsResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    struct Message: Decodable { let content: String? }
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

private struct StreamChunk: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let delta: Delta
    }
    struct Delta: Decodable { let content: String? }
}
