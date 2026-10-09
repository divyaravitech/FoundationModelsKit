import Foundation

// MARK: - Core Protocol

/// The single entry-point that every model backend must satisfy.
/// Conformers include on-device models, Private Cloud Compute relays,
/// third-party API wrappers, and test mocks.
public protocol LanguageModelProviding: Sendable {
    /// Sends a request and returns the complete response.
    func respond(to request: ModelRequest) async throws -> ModelResponse

    /// Whether this backend can run the tools a request asks for.
    ///
    /// ``ModelRouter`` uses it to decide whether a tool-using request may stay
    /// on-device. Defaults to `true`, which is right for cloud backends.
    var supportsTools: Bool { get }

    /// Streams the response in chunks.
    ///
    /// The default implementation calls ``respond(to:)`` and yields the whole
    /// body as one chunk, so every backend works at the call site. Override it
    /// where the provider streams natively.
    func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, Error>
}

public extension LanguageModelProviding {
    var supportsTools: Bool { true }

    func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await respond(to: request)
                    try Task.checkCancellation()
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // An early break must not leave the request running.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// Pre-2.0 spelling. Callers keep compiling with a warning pointing at the fix.
public extension LanguageModelProviding {
    @available(*, deprecated, renamed: "respond(to:)")
    func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        try await respond(to: request)
    }

    @available(*, deprecated, renamed: "streamResponse(to:)")
    func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: request)
    }
}

// MARK: - Request

/// Everything a caller needs to express a single inference turn.
public struct ModelRequest: Sendable, Codable, Equatable, Hashable {
    /// The user-facing text prompt or continuation.
    public var content: String

    /// Names of tools this request needs, used for routing.
    ///
    /// A non-empty value keeps the request off the on-device path, which has
    /// no tool support. Execution is separate: register the tools themselves
    /// on the backend (`AnthropicLanguageModel(config:tools:)`), because a
    /// `Tool` holds a closure and so cannot live in a `Codable` request.
    public var tools: [String]?

    /// How sensitive the payload is — used by the router to avoid sending
    /// private data to third-party endpoints.
    public var privacySensitivity: PrivacySensitivity

    /// Hint about expected reasoning depth — used by the router to pick
    /// an appropriately capable (and appropriately private) backend.
    public var taskComplexity: TaskComplexity

    public init(
        content: String,
        tools: [String]? = nil,
        privacySensitivity: PrivacySensitivity = .medium,
        taskComplexity: TaskComplexity = .medium
    ) {
        self.content = content
        self.tools = tools
        self.privacySensitivity = privacySensitivity
        self.taskComplexity = taskComplexity
    }
}

// MARK: - Response

/// The model's reply for a single inference turn.
public struct ModelResponse: Sendable, Codable, Equatable {
    /// The generated text.
    public var content: String

    /// Why the model stopped generating (e.g. "end_turn", "max_tokens",
    /// "tool_use").
    public var stopReason: String

    /// Token accounting for cost tracking and context-window management.
    public var usage: TokenUsage

    public init(content: String, stopReason: String, usage: TokenUsage) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }
}

// MARK: - Token Usage

public struct TokenUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    /// Tokens served from the prompt cache (subset of `inputTokens`).
    public var cachedInputTokens: Int

    /// `true` when these counts were estimated rather than reported by the
    /// backend. On-device models do not expose exact token counts, so
    /// `OnDeviceLanguageModel` returns estimates flagged with this property.
    ///
    /// Do not use estimated counts for billing or quota enforcement.
    public var isEstimated: Bool

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        isEstimated: Bool = false
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.isEstimated = isEstimated
    }

    /// Net new tokens billed (excludes cache hits).
    public var billableInputTokens: Int { inputTokens - cachedInputTokens }

    /// Characters per token, averaged over English prose.
    ///
    /// Materially wrong for code, CJK text, and heavy punctuation — replacing
    /// this with a real tokenizer is tracked in issue #5. Anything derived from
    /// it is marked ``isEstimated``.
    public static let charactersPerToken = 4

    /// Builds a `TokenUsage` from character counts, flagged `isEstimated == true`.
    ///
    /// Used by backends that do not report exact counts. Never returns zero —
    /// callers divide by these values when budgeting context.
    public static func estimated(promptChars: Int, completionChars: Int) -> TokenUsage {
        TokenUsage(
            inputTokens: Swift.max(1, promptChars / charactersPerToken),
            outputTokens: Swift.max(1, completionChars / charactersPerToken),
            isEstimated: true
        )
    }

    // MARK: Codable

    // Hand-written: synthesized Codable ignores defaults and throws on a
    // missing key, breaking data saved before a field was added.
    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedInputTokens, isEstimated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        self.outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        self.cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        self.isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }
}

// MARK: - Enums

/// Which deployment tier handles the request.
public enum ModelTier: String, Sendable, Codable, CaseIterable, Hashable {
    /// Apple Neural Engine / Core ML — stays entirely on device.
    case onDevice
    /// Apple Private Cloud Compute — leaves the device but never reaches
    /// a third-party server.
    case pcc
    /// External provider (Anthropic, OpenAI, etc.).
    case thirdParty
}

/// Caller-declared sensitivity of the request payload.
/// The router uses this to enforce data-residency constraints.
public enum PrivacySensitivity: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    private var order: Int {
        switch self { case .low: 0; case .medium: 1; case .high: 2 }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
    case low
    case medium
    case high
}

/// Caller-declared reasoning complexity required for the task.
/// Simple tasks can stay on-device; complex tasks may need a larger model.
public enum TaskComplexity: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    private var order: Int {
        switch self { case .simple: 0; case .medium: 1; case .complex: 2 }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
    case simple
    case medium
    case complex
}

// MARK: - Errors

public enum LanguageModelError: LocalizedError, Equatable {
    /// The requested backend is not available (model not downloaded,
    /// network offline, quota exhausted, etc.).
    case unavailable

    /// The combined prompt + history exceeds the model's context window.
    case contextWindowExceeded

    /// The model asked for a tool that is not registered with this backend.
    case toolNotSupported(String)

    /// The model kept calling tools past the backend's turn limit.
    case toolLoopLimitExceeded(turns: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The language model is currently unavailable."
        case .contextWindowExceeded:
            return "The request exceeds the model's context window limit."
        case .toolNotSupported(let name):
            return "Tool '\(name)' is not supported by this model backend."
        case .toolLoopLimitExceeded(let turns):
            return "The model kept requesting tools after \(turns) turns."
        }
    }
}
