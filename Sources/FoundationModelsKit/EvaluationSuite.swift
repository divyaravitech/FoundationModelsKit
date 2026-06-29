// EvaluationSuite.swift
// Evaluates model outputs against quality, safety, and consistency criteria.
//
// Custom metrics conform to EvaluationMetric and are injected at init time,
// so the suite never hard-codes what "good" means for a given use-case.

import Foundation

// MARK: - Protocol

/// A single, named evaluation criterion.
public protocol EvaluationMetric: Sendable {
    /// Human-readable identifier shown in reports and logs.
    var name: String { get }

    /// Score the response. Must be safe to call from any concurrency context.
    func evaluate(response: ModelResponse) async -> EvaluationScore
}

// MARK: - Score

/// The result of applying one metric to one response.
public struct EvaluationScore: Sendable, Codable {
    /// Matches `EvaluationMetric.name` so scores can be correlated back to
    /// the metric that produced them.
    public var metricName: String

    /// Normalised quality signal in [0.0, 1.0]. 1.0 is best.
    public var score: Double

    /// Convenience flag: `true` when `score >= metric threshold`.
    public var passed: Bool

    /// Optional human-readable explanation (failure reason, matched keywords…).
    public var details: String?

    public init(metricName: String, score: Double, passed: Bool, details: String? = nil) {
        self.metricName = metricName
        self.score = score
        self.passed = passed
        self.details = details
    }
}

// MARK: - Result

/// Aggregated outcome for a single model response across all metrics.
public struct EvaluationResult: Sendable, Codable {
    /// Caller-supplied identifier that links this result back to a request.
    public var responseID: String

    /// One score per metric, in the order the suite evaluated them.
    public var scores: [EvaluationScore]

    /// `true` only when every individual score passed.
    public var overallPassed: Bool

    /// Wall-clock time the evaluation completed.
    public var timestamp: Date

    public init(
        responseID: String,
        scores: [EvaluationScore],
        overallPassed: Bool,
        timestamp: Date = Date()
    ) {
        self.responseID = responseID
        self.scores = scores
        self.overallPassed = overallPassed
        self.timestamp = timestamp
    }
}

// MARK: - Suite

/// Actor-isolated runner that applies a fixed set of metrics to one or more
/// model responses.
///
/// Usage:
/// ```swift
/// let suite = EvaluationSuite(metrics: [
///     NonEmptyMetric(),
///     LengthMetric(min: 10, max: 500),
///     ContainsKeywordsMetric(keywords: ["summary", "conclusion"]),
/// ])
/// let result = await suite.evaluate(response: response, responseID: "turn-1")
/// ```
public actor EvaluationSuite: Sendable {
    private let metrics: [any EvaluationMetric]

    public init(metrics: [any EvaluationMetric]) {
        self.metrics = metrics
    }

    /// Runs all metrics against `response` and returns an aggregated result.
    public func evaluate(response: ModelResponse, responseID: String) async -> EvaluationResult {
        var scores: [EvaluationScore] = []

        for metric in metrics {
            let score = await metric.evaluate(response: response)
            scores.append(score)
        }

        let overallPassed = scores.allSatisfy(\.passed)
        return EvaluationResult(
            responseID: responseID,
            scores: scores,
            overallPassed: overallPassed,
            timestamp: Date()
        )
    }

    /// Evaluates a batch of responses, assigning auto-generated IDs
    /// (`"response-0"`, `"response-1"`, …) when the caller doesn't need
    /// to supply explicit identifiers.
    public func evaluateBatch(responses: [ModelResponse]) async -> [EvaluationResult] {
        var results: [EvaluationResult] = []
        for (index, response) in responses.enumerated() {
            let result = await evaluate(response: response, responseID: "response-\(index)")
            results.append(result)
        }
        return results
    }
}

// MARK: - Built-in metrics

/// Fails when the response body is empty or contains only whitespace.
public struct NonEmptyMetric: EvaluationMetric, Sendable {
    public let name = "NonEmpty"

    public init() {}

    public func evaluate(response: ModelResponse) async -> EvaluationScore {
        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let passed = !trimmed.isEmpty
        return EvaluationScore(
            metricName: name,
            score: passed ? 1.0 : 0.0,
            passed: passed,
            details: passed ? nil : "Response was empty or whitespace-only."
        )
    }
}

/// Checks that the response length falls within an inclusive character range.
public struct LengthMetric: EvaluationMetric, Sendable {
    public let name = "Length"
    public let min: Int
    public let max: Int

    public init(min: Int = 1, max: Int = 4000) {
        self.min = min
        self.max = max
    }

    public func evaluate(response: ModelResponse) async -> EvaluationScore {
        let length = response.content.count
        let passed = length >= min && length <= max

        // Normalise: 1.0 at the ideal midpoint, falling toward 0 at the edges.
        let midpoint = Double(min + max) / 2.0
        let halfRange = Double(max - min) / 2.0
        let raw = halfRange > 0 ? 1.0 - abs(Double(length) - midpoint) / halfRange : (passed ? 1.0 : 0.0)
        let score = Swift.max(0.0, raw)

        let details = passed
            ? "Length \(length) is within [\(min), \(max)]."
            : "Length \(length) is outside [\(min), \(max)]."

        return EvaluationScore(metricName: name, score: score, passed: passed, details: details)
    }
}

/// Checks that the response contains all required keywords (case-insensitive).
public struct ContainsKeywordsMetric: EvaluationMetric, Sendable {
    public let name = "ContainsKeywords"

    /// All of these must appear in the response for it to pass.
    public let keywords: [String]

    public init(keywords: [String]) {
        self.keywords = keywords
    }

    public func evaluate(response: ModelResponse) async -> EvaluationScore {
        guard !keywords.isEmpty else {
            return EvaluationScore(metricName: name, score: 1.0, passed: true,
                                   details: "No keywords specified.")
        }

        let lowercased = response.content.lowercased()
        let found = keywords.filter { lowercased.contains($0.lowercased()) }
        let score = Double(found.count) / Double(keywords.count)
        let passed = found.count == keywords.count

        let missing = keywords.filter { !lowercased.contains($0.lowercased()) }
        let details = passed
            ? "All \(keywords.count) keyword(s) found."
            : "Missing keyword(s): \(missing.joined(separator: ", "))"

        return EvaluationScore(metricName: name, score: score, passed: passed, details: details)
    }
}
