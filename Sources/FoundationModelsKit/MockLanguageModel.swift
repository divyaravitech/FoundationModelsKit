// MockLanguageModel.swift
// Deterministic test double for LanguageModelProviding.
//
// Use in unit tests and SwiftUI previews where a real model backend
// would be too slow, require network access, or introduce flakiness.

import Foundation

/// A lightweight, actor-isolated fake that satisfies `LanguageModelProviding`.
///
/// Usage:
/// ```swift
/// let mock = MockLanguageModel()
/// let response = try await mock.sendMessage(request: ModelRequest(content: "Hello"))
/// let calls = await mock.callCount   // 1
/// ```
public actor MockLanguageModel: LanguageModelProviding {

    /// Number of times `sendMessage` has been called. Useful for assertions
    /// like "the router only called the model once despite two identical prompts."
    public private(set) var callCount: Int = 0

    /// The last request received, for post-hoc inspection in tests.
    public private(set) var lastRequest: ModelRequest?

    /// Override this closure to return different responses per call or to
    /// simulate errors (`throw LanguageModelError.unavailable`).
    ///
    /// Defaults to a canned success response.
    public var responseHandler: @Sendable (ModelRequest) async throws -> ModelResponse

    public init(
        responseHandler: (@Sendable (ModelRequest) async throws -> ModelResponse)? = nil
    ) {
        self.responseHandler = responseHandler ?? MockLanguageModel.defaultHandler
    }

    // MARK: - LanguageModelProviding

    public func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        callCount += 1
        lastRequest = request
        return try await responseHandler(request)
    }

    // MARK: - Helpers

    /// Resets call tracking without replacing the response handler.
    public func reset() {
        callCount = 0
        lastRequest = nil
    }

    // MARK: - Default handler

    static let defaultHandler: @Sendable (ModelRequest) async throws -> ModelResponse = { _ in
        ModelResponse(
            content: "This is a mock response for testing.",
            stopReason: "end_turn",
            usage: TokenUsage(
                inputTokens: 10,
                outputTokens: 8,
                cachedInputTokens: 0
            )
        )
    }
}
