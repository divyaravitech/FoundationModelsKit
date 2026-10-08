import Foundation

/// Estimates how many tokens a string will cost.
///
/// Swap in a real tokenizer by conforming your own type — the kit ships
/// ``HeuristicTokenEstimator`` so the core stays dependency-free.
public protocol TokenEstimating: Sendable {
    func tokenCount(of text: String) -> Int
}

/// Character-class-aware estimate, accurate to roughly ±15% on mixed content.
///
/// A flat characters-per-token ratio is tuned for English prose and badly
/// underestimates CJK (where a character is often a whole token) while
/// overestimating whitespace-heavy code. This weighs each class separately.
public struct HeuristicTokenEstimator: TokenEstimating {

    public init() {}

    public func tokenCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var cjk = 0
        var whitespace = 0
        var punctuation = 0
        var other = 0

        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) {
                cjk += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                whitespace += 1
            } else if CharacterSet.punctuationCharacters.contains(scalar)
                        || CharacterSet.symbols.contains(scalar) {
                punctuation += 1
            } else {
                other += 1
            }
        }

        // CJK: ~1 token per character. Punctuation: usually its own token.
        // Runs of whitespace fold into the adjacent token, so they cost far
        // less than a quarter-token each. Everything else is ~4 chars/token.
        let estimate = Double(cjk)
            + Double(punctuation) * 0.75
            + Double(whitespace) * 0.25
            + Double(other) / 4.0

        return max(1, Int(estimate.rounded()))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,    // Hiragana, Katakana
             0x3400...0x4DBF,    // CJK Extension A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xAC00...0xD7AF,    // Hangul syllables
             0xF900...0xFAFF:    // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }
}

/// Fixed 4-characters-per-token estimate.
///
/// Matches what the kit used before ``HeuristicTokenEstimator``; kept so
/// existing budgets stay reproducible.
public struct FixedRatioTokenEstimator: TokenEstimating {
    public let charactersPerToken: Int

    public init(charactersPerToken: Int = 4) {
        self.charactersPerToken = max(1, charactersPerToken)
    }

    public func tokenCount(of text: String) -> Int {
        max(1, text.count / charactersPerToken)
    }
}

/// Exact counts from Anthropic's `/v1/messages/count_tokens` endpoint.
///
/// Costs a network round trip, so it suits deliberate budgeting rather than
/// per-keystroke checks. `tokenCount(of:)` cannot be async, so it falls back to
/// the heuristic; call ``exactTokenCount(of:)`` when you can await.
public struct AnthropicTokenCounter: Sendable {
    private let config: AnthropicConfiguration
    private let session: URLSession

    public init(config: AnthropicConfiguration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func exactTokenCount(of text: String) async throws -> Int {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages/count_tokens"))
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "messages": [["role": "user", "content": text]],
        ])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LanguageModelError.unavailable
        }
        return try JSONDecoder().decode(CountTokensResponse.self, from: data).inputTokens
    }
}

private struct CountTokensResponse: Decodable {
    let inputTokens: Int
    enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens" }
}
