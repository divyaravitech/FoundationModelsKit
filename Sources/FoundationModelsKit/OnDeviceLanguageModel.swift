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
/// let response = try await model.respond(
///     to: ModelRequest(content: "Summarise this.", privacySensitivity: .high)
/// )
/// ```
public struct OnDeviceLanguageModel: LanguageModelProviding, Sendable {

    private let tools: [any ModelTool]

    /// - Parameter tools: Tools the model may call. Their JSON Schemas are
    ///   converted to Apple's runtime schema type, so no `@Generable` type is
    ///   needed. A tool whose schema cannot be converted throws at call time.
    public init(tools: [any ModelTool] = []) {
        self.tools = tools
    }

    // MARK: - LanguageModelProviding

    /// Only when tools were registered — the framework has no ad-hoc tool path.
    public var supportsTools: Bool { !tools.isEmpty }

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            throw LanguageModelError.unavailable
        }
        do {
            let session = try makeSession()
            let result = try await session.respond(to: request.content)
            // The framework exposes no token counts, so these are estimates.
            return ModelResponse(
                content: result.content,
                stopReason: "end_turn",
                usage: .estimated(
                    promptChars: request.content.count,
                    completionChars: result.content.count
                )
            )
        } catch {
            throw LanguageModelError.unavailable
        }
#else
        throw LanguageModelError.unavailable
#endif
    }

    public func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
#if canImport(FoundationModels)
                guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
                    continuation.finish(throwing: LanguageModelError.unavailable)
                    return
                }
                do {
                    let session = try makeSession()
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: request.content) {
                        try Task.checkCancellation()
                        // Yield only the delta since the last snapshot.
                        let full = snapshot.content
                        let delta = String(full.dropFirst(previous.count))
                        if !delta.isEmpty { continuation.yield(delta) }
                        previous = full
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LanguageModelError.unavailable)
                }
#else
                continuation.finish(throwing: LanguageModelError.unavailable)
#endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Session

#if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func makeSession() throws -> LanguageModelSession {
        guard !tools.isEmpty else { return LanguageModelSession() }
        return LanguageModelSession(tools: try tools.map(OnDeviceToolAdapter.init))
    }
#endif

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
