import Foundation

/// Plumbing shared by the HTTP-based backends.
///
/// Only the parts that are genuinely identical live here. Request bodies,
/// auth headers and response shapes differ per provider and stay in each
/// backend, where they are easier to compare against that provider's docs.
enum HTTPBackend {

    /// Status codes worth retrying.
    ///
    /// These become ``LanguageModelError/unavailable`` so ``RetryingLanguageModel``
    /// backs off. Anything else is a client error: the same request would fail
    /// the same way, so it surfaces with the server's detail instead.
    static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    /// Payload of one `data:` line in a server-sent event stream.
    ///
    /// Returns `nil` for lines that carry no payload — comments, blank
    /// separators, and the `event:` lines some providers interleave.
    static func ssePayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    /// Whether an SSE payload is the end-of-stream sentinel.
    static func isStreamTerminator(_ payload: String) -> Bool {
        payload == "[DONE]"
    }
}
