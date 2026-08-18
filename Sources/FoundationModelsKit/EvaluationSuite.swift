// EvaluationSuite.swift
// Evaluates model outputs against quality, safety, and consistency criteria.
//
// Custom metrics conform to EvaluationMetric and are injected at init time.

import Foundation

// MARK: - Protocol

/// A single, named evaluation criterion.
public protocol EvaluationMetric: Sendable {
    var name: String { get }
    func evaluate(response: ModelResponse) async -> EvaluationScore
}

// MARK: - Score

/// The result of applying one metric to one response.
public struct EvaluationScore: Sendable, Codable {
    /// Matches `EvaluationMetric.name`.
    public var metricName: String

    /// Normalised quality signal in [0.0, 1.0]. 1.0 is best.
    public var score: Double

    /// `true` when the response satisfies this metric's pass threshold.
    public var passed: Bool

    /// Optional human-readable explanation.
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
    public var responseID: String
    public var scores: [EvaluationScore]

    /// `true` only when every individual score passed.
    public var overallPassed: Bool

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

    /// Average score across all metrics.
    public var averageScore: Double {
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0) { $0 + $1.score } / Double(scores.count)
    }
}

// MARK: - Suite

/// Actor-isolated runner that applies a fixed set of metrics to responses.
///
/// Usage:
/// ```swift
/// let suite = EvaluationSuite(metrics: [
///     NonEmptyMetric(),
///     LengthMetric(min: 10, max: 500),
///     ContainsKeywordsMetric(keywords: ["summary"]),
/// ])
/// let result = await suite.evaluate(response: response, responseID: "turn-1")
/// ```
public actor EvaluationSuite: Sendable {
    private let metrics: [any EvaluationMetric]

    public init(metrics: [any EvaluationMetric]) {
        self.metrics = metrics
    }

    /// Runs all metrics against `response` concurrently and returns an
    /// aggregated result. Result order matches metric insertion order.
    public func evaluate(response: ModelResponse, responseID: String) async -> EvaluationResult {
        let scores = await withTaskGroup(
            of: (index: Int, score: EvaluationScore).self,
            returning: [EvaluationScore].self
        ) { group in
            for (index, metric) in metrics.enumerated() {
                group.addTask {
                    let score = await metric.evaluate(response: response)
                    return (index, score)
                }
            }

            // Collect and sort by original index to preserve metric order.
            var unsorted: [(index: Int, score: EvaluationScore)] = []
            for await pair in group { unsorted.append(pair) }
            return unsorted.sorted { $0.index < $1.index }.map(\.score)
        }

        return EvaluationResult(
            responseID: responseID,
            scores: scores,
            overallPassed: scores.allSatisfy(\.passed),
            timestamp: Date()
        )
    }

    /// Evaluates a batch of responses concurrently. IDs default to
    /// `"response-0"`, `"response-1"`, … Results preserve input order.
    public func evaluateBatch(responses: [ModelResponse]) async -> [EvaluationResult] {
        await withTaskGroup(
            of: (index: Int, result: EvaluationResult).self,
            returning: [EvaluationResult].self
        ) { group in
            for (index, response) in responses.enumerated() {
                group.addTask {
                    let result = await self.evaluate(
                        response: response,
                        responseID: "response-\(index)"
                    )
                    return (index, result)
                }
            }
            var unsorted: [(index: Int, result: EvaluationResult)] = []
            for await pair in group { unsorted.append(pair) }
            return unsorted.sorted { $0.index < $1.index }.map(\.result)
        }
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

/// Checks that the response length (in characters) falls within [min, max].
///
/// Score is 1.0 anywhere inside the range and falls linearly to 0 outside it,
/// so boundary values always score 1.0 when `passed` is `true`.
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

        // Score: 1.0 anywhere in [min, max]; decreases linearly outside.
        let score: Double
        if passed {
            score = 1.0
        } else if length < min {
            let overshoot = Double(min - length)
            score = Swift.max(0.0, 1.0 - overshoot / Double(Swift.max(min, 1)))
        } else {
            let overshoot = Double(length - max)
            score = Swift.max(0.0, 1.0 - overshoot / Double(Swift.max(max, 1)))
        }

        let details = passed
            ? "Length \(length) is within [\(min), \(max)]."
            : "Length \(length) is outside [\(min), \(max)]."

        return EvaluationScore(metricName: name, score: score, passed: passed, details: details)
    }
}

/// Checks that the response contains all required keywords (case-insensitive).
/// Partial matches receive proportional credit (e.g. 3 of 4 → score 0.75).
public struct ContainsKeywordsMetric: EvaluationMetric, Sendable {
    public let name = "ContainsKeywords"
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
        let found   = keywords.filter { lowercased.contains($0.lowercased()) }
        let missing = keywords.filter { !lowercased.contains($0.lowercased()) }
        let score   = Double(found.count) / Double(keywords.count)
        let passed  = missing.isEmpty

        let details = passed
            ? "All \(keywords.count) keyword(s) found."
            : "Missing: \(missing.joined(separator: ", "))"

        return EvaluationScore(metricName: name, score: score, passed: passed, details: details)
    }
}
