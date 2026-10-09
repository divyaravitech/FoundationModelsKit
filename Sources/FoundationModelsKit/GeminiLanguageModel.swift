import Foundation

/// Credentials and model selection for the Gemini backend.
public struct GeminiConfiguration: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var baseURL: URL

    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!
    public static let defaultModel = "gemini-2.0-flash"

    public init(
        apiKey: String,
        model: String = GeminiConfiguration.defaultModel,
        maxTokens: Int = 1024,
        baseURL: URL = GeminiConfiguration.defaultBaseURL
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }
}

extension GeminiConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "GeminiConfiguration(model: \(model), maxTokens: \(maxTokens), baseURL: \(baseURL), apiKey: <redacted>)"
    }
    public var debugDescription: String { description }
}

/// Calls the Gemini `generateContent` API.
///
/// ```swift
/// guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
///     throw ConfigError.missingAPIKey
/// }
/// let gemini = GeminiLanguageModel(config: GeminiConfiguration(apiKey: key))
/// ```
public struct GeminiLanguageModel: LanguageModelProviding, Sendable {

    private let config: GeminiConfiguration
    private let session: URLSession

    public init(config: GeminiConfiguration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        let urlRequest = try makeRequest(for: request, stream: false)
        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decode(data: data)
    }

    public func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, Error> {
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
                        guard
                            let data = payload.data(using: .utf8),
                            let chunk = try? JSONDecoder().decode(GenerateContentResponse.self, from: data),
                            let text = chunk.candidates?.first?.content.parts.first?.text
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
        let method = stream ? "streamGenerateContent" : "generateContent"
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("v1beta/models/\(config.model):\(method)"),
            resolvingAgainstBaseURL: false
        )
        var query = [URLQueryItem(name: "key", value: config.apiKey)]
        if stream { query.append(URLQueryItem(name: "alt", value: "sse")) }
        components?.queryItems = query

        guard let url = components?.url else {
            throw GeminiError.apiError(statusCode: 0, body: "could not build request URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": request.content]]]],
            "generationConfig": ["maxOutputTokens": config.maxTokens],
        ])
        return urlRequest
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if Self.isTransient(statusCode: http.statusCode) {
                throw LanguageModelError.unavailable
            }
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw GeminiError.apiError(statusCode: http.statusCode, body: detail)
        }
    }

    private func decode(data: Data) throws -> ModelResponse {
        let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        guard let candidate = decoded.candidates?.first else {
            throw GeminiError.apiError(statusCode: 200, body: "response contained no candidates")
        }
        let text = candidate.content.parts.compactMap(\.text).joined()
        return ModelResponse(
            content: text,
            stopReason: candidate.finishReason ?? "STOP",
            usage: TokenUsage(
                inputTokens: decoded.usageMetadata?.promptTokenCount ?? 0,
                outputTokens: decoded.usageMetadata?.candidatesTokenCount ?? 0
            )
        )
    }
}

public enum GeminiError: LocalizedError, Equatable {
    case apiError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .apiError(let code, let body):
            return "Gemini API error \(code): \(body)"
        }
    }
}

private struct GenerateContentResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?

    struct Candidate: Decodable {
        let content: Content
        let finishReason: String?
    }
    struct Content: Decodable {
        let parts: [Part]
    }
    struct Part: Decodable {
        let text: String?
    }
    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
    }
}
