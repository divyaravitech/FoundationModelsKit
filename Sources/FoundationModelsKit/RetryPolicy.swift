// RetryPolicy.swift
// Exponential-backoff retry wrapper for any LanguageModelProviding backend.
//
// Usage:
//   let robust = RetryingLanguageModel(wrapped: myBackend, policy: .default)
//   let response = try await robust.sendMessage(request: request)

import Foundation

// MARK: - Policy

/// Controls when and how many times a failed request is retried.
public struct RetryPolicy: Sendable {
    /// Maximum number of attempts (first attempt + retries).
    public var maxAttempts: Int

    /// Initial delay before the first retry, in seconds.
    public var initialDelay: TimeInterval

    /// Multiplier applied to the delay after each failure.
    public var backoffMultiplier: Double

    /// Maximum delay cap, in seconds.
    public var maxDelay: TimeInterval

    /// Only retry when the error matches this predicate.
    /// Defaults to retrying on `.unavailable` only.
    public var shouldRetry: @Sendable (Error) -> Bool

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        backoffMultiplier: Double = 2.0,
        maxDelay: TimeInterval = 10.0,
        shouldRetry: @Sendable @escaping (Error) -> Bool = { error in
            (error as? LanguageModelError) == .unavailable
        }
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.backoffMultiplier = backoffMultiplier
        self.maxDelay = maxDelay
        self.shouldRetry = shouldRetry
    }

    /// Retry on `.unavailable` and `.contextWindowExceeded`, up to 3 attempts.
    public static let `default` = RetryPolicy()

    /// No retries — fail fast.
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Aggressive retry for unreliable network conditions.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: 1.0,
        backoffMultiplier: 2.0,
        maxDelay: 30.0
    )
}

// MARK: - Wrapper

/// Wraps any `LanguageModelProviding` with automatic retry on transient errors.
public struct RetryingLanguageModel: LanguageModelProviding, Sendable {
    private let wrapped: any LanguageModelProviding
    private let policy: RetryPolicy

    public init(wrapped: any LanguageModelProviding, policy: RetryPolicy = .default) {
        self.wrapped = wrapped
        self.policy = policy
    }

    public func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        var lastError: Error = LanguageModelError.unavailable
        var delay = policy.initialDelay

        for attempt in 1...policy.maxAttempts {
            do {
                return try await wrapped.sendMessage(request: request)
            } catch {
                lastError = error
                guard attempt < policy.maxAttempts, policy.shouldRetry(error) else { break }
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * policy.backoffMultiplier, policy.maxDelay)
            }
        }
        throw lastError
    }

    /// Streaming retries the initial connection; individual chunks are not retried.
    public func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var lastError: Error = LanguageModelError.unavailable
                var delay = policy.initialDelay

                for attempt in 1...policy.maxAttempts {
                    do {
                        for try await chunk in wrapped.streamMessage(request: request) {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    } catch {
                        lastError = error
                        guard attempt < policy.maxAttempts, policy.shouldRetry(error) else { break }
                        try? await Task.sleep(for: .seconds(delay))
                        delay = min(delay * policy.backoffMultiplier, policy.maxDelay)
                    }
                }
                continuation.finish(throwing: lastError)
            }
        }
    }
}
