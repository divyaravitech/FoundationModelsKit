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
    func sendMessage(request: ModelRequest) async throws -> ModelResponse
}

// MARK: - Request

/// Everything a caller needs to express a single inference turn.
public struct ModelRequest: Sendable, Codable {
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
public struct ModelResponse: Sendable, Codable {
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

public struct TokenUsage: Sendable, Codable {
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
}

// MARK: - Enums

/// Which deployment tier handles the request.
public enum ModelTier: String, Sendable, Codable, CaseIterable {
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
public enum PrivacySensitivity: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
}

/// Caller-declared reasoning complexity required for the task.
/// Simple tasks can stay on-device; complex tasks may need a larger model.
public enum TaskComplexity: String, Sendable, Codable, CaseIterable {
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
