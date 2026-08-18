// OnDeviceLanguageModel.swift
// Wraps Apple's FoundationModels framework (available macOS 26 / iOS 26+).
// Compiles on older targets — throws .unavailable at runtime when the
// framework is absent or Apple Intelligence is not enabled on the device.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device language model powered by Apple Intelligence.
///
/// All inference runs on the Apple Neural Engine — no data ever leaves the
/// device. Suitable for any `privacySensitivity`, including `.high`.
///
/// ```swift
/// guard OnDeviceLanguageModel.isAvailable else {
///     // Fall back to a cloud backend
///     return
/// }
/// let model = OnDeviceLanguageModel()
/// let response = try await model.sendMessage(
///     request: ModelRequest(content: "Summarise this.", privacySensitivity: .high)
/// )
/// ```
public struct OnDeviceLanguageModel: LanguageModelProviding, Sendable {

    public init() {}

    // MARK: - LanguageModelProviding

    public func sendMessage(request: ModelRequest) async throws -> ModelResponse {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            throw LanguageModelError.unavailable
        }
        do {
            let session = LanguageModelSession()
            let result = try await session.respond(to: request.content)
            return ModelResponse(
                content: result.content,
                stopReason: "end_turn",
                usage: TokenUsage(inputTokens: 0, outputTokens: 0)
            )
        } catch {
            throw LanguageModelError.unavailable
        }
#else
        throw LanguageModelError.unavailable
#endif
    }

    public func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
#if canImport(FoundationModels)
                guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
                    continuation.finish(throwing: LanguageModelError.unavailable)
                    return
                }
                do {
                    let session = LanguageModelSession()
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: request.content) {
                        // Yield only the delta since the last snapshot.
                        let full = snapshot.content
                        let delta = String(full.dropFirst(previous.count))
                        if !delta.isEmpty { continuation.yield(delta) }
                        previous = full
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LanguageModelError.unavailable)
                }
#else
                continuation.finish(throwing: LanguageModelError.unavailable)
#endif
            }
        }
    }

    // MARK: - Availability

    /// `true` when Apple Intelligence is available on this device and OS version.
    public static var isAvailable: Bool {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
#else
        return false
#endif
    }
}
