// LanguageModelProviding.swift
// Core protocol and data types for FoundationModelsKit.
//
// Design: all types are Sendable + Codable so they can cross actor boundaries
// and be serialized to disk or over the wire without extra conversion layers.

import Foundation

// MARK: - Core Protocol

/// The single entry-point that every model backend must satisfy.
/// Conformers include on-device models, Private Cloud Compute relays,
/// third-party API wrappers, and test mocks.
public protocol LanguageModelProviding: Sendable {
    /// Sends a request and returns the complete response.
    func sendMessage(request: ModelRequest) async throws -> ModelResponse

    /// Streams the response token-by-token as an `AsyncThrowingStream<String, Error>`.
    ///
    /// A default implementation is provided that calls `sendMessage` and yields
    /// the full content as a single chunk. Backends that support native streaming
    /// (e.g. Anthropic SSE, Apple FoundationModels) should override this.
    func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error>
}

public extension LanguageModelProviding {
    func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await sendMessage(request: request)
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Request

/// Everything a caller needs to express a single inference turn.
public struct ModelRequest: Sendable, Codable, Equatable, Hashable {
    /// The user-facing text prompt or continuation.
    public var content: String

    /// Names of tools the model may invoke. `nil` means no tools available.
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
    /// Tokens served from the prompt cache (subset of inputTokens).
    public var cachedInputTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    /// Net new tokens billed (excludes cache hits).
    public var billableInputTokens: Int { inputTokens - cachedInputTokens }

    /// `true` when these counts were estimated rather than reported by the
    /// backend. On-device models do not currently expose exact token counts,
    /// so `OnDeviceLanguageModel` returns estimates flagged with this property.
    ///
    /// Do not use estimated counts for billing or quota enforcement.
    public var isEstimated: Bool = false

    /// Builds a `TokenUsage` from character counts using the standard
    /// ~4-characters-per-token heuristic for English text.
    ///
    /// Used by backends that do not report exact counts. The result is always
    /// marked `isEstimated == true`.
    public static func estimated(promptChars: Int, completionChars: Int) -> TokenUsage {
        var usage = TokenUsage(
            inputTokens: Swift.max(1, promptChars / 4),
            outputTokens: Swift.max(1, completionChars / 4)
        )
        usage.isEstimated = true
        return usage
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

    /// A tool name in `ModelRequest.tools` is not registered with this backend.
    case toolNotSupported(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The language model is currently unavailable."
        case .contextWindowExceeded:
            return "The request exceeds the model's context window limit."
        case .toolNotSupported(let name):
            return "Tool '\(name)' is not supported by this model backend."
        }
    }
}
