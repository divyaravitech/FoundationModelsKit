import Foundation

// MARK: - Configuration

/// Declarative configuration for the entire SDK stack.
public struct FoundationModelsKitConfiguration: Sendable, Codable {
    /// Routing and context-management preferences.
    public var profile: DynamicProfile

    /// Whether responses are evaluated, and a label for *what* is being run.
    ///
    /// - Important: This field does **not** select metrics. The
    ///   `EvaluationSuite` passed to `SDKIntegration.init` decides which
    ///   metrics run — that is the only way to use a custom metric. An empty
    ///   array here disables evaluation entirely; any non-empty array enables
    ///   it. The contents serve as documentation and appear in diagnostics.
    public var evaluationMetrics: [String]

    /// When `true`, consults `RegionalAvailability` before routing.
    public var regionAwareness: Bool

    /// When `true`, each request/response cycle appends a diagnostic entry.
    public var loggingEnabled: Bool

    public init(
        profile: DynamicProfile = .balanced,
        evaluationMetrics: [String] = ["NonEmpty", "Length"],
        regionAwareness: Bool = true,
        loggingEnabled: Bool = true
    ) {
        self.profile = profile
        self.evaluationMetrics = evaluationMetrics
        self.regionAwareness = regionAwareness
        self.loggingEnabled = loggingEnabled
    }
}

// MARK: - Diagnostic entry

// Not Sendable, but only read after setup.
private nonisolated(unsafe) let sharedISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private struct DiagnosticEntry: Sendable {
    let timestamp: Date
    let requestSnippet: String
    let tier: ModelTier?
    let responseSnippet: String
    let evaluationPassed: Bool?
    let errorDescription: String?

    func formatted() -> String {
        let ts = sharedISO8601Formatter.string(from: timestamp)
        let tierLabel = tier.map(\.rawValue) ?? "unknown"
        let evalLabel: String
        switch evaluationPassed {
        case .some(true):  evalLabel = "✓ eval passed"
        case .some(false): evalLabel = "✗ eval failed"
        case .none:        evalLabel = "eval skipped"
        }
        if let err = errorDescription {
            return "[\(ts)] tier=\(tierLabel) ERROR: \(err)"
        }
        return "[\(ts)] tier=\(tierLabel) \(evalLabel)\n  req: \(requestSnippet)\n  res: \(responseSnippet)"
    }

}

// MARK: - Facade

/// Single entry point for the FoundationModelsKit stack.
///
/// `SDKIntegration` orchestrates:
/// 1. Region check (optional) — resolves the best available tier
/// 2. Auto-compaction of the conversation store
/// 3. Routing via `ModelRouter`
/// 4. Evaluation via the injected `EvaluationSuite`
/// 5. Transcript management in `ConversationStore`
/// 6. Diagnostic logging
///
/// The stored properties are actors held as their concrete types, which is
/// intentional for this facade: the composition seam is the `init` signature,
/// where each collaborator can be replaced with any conforming actor in tests.
public actor SDKIntegration: Sendable {

    private let config: FoundationModelsKitConfiguration
    private let router: ModelRouter
    private let store: ConversationStore
    private let evaluation: EvaluationSuite
    private let regional: RegionalAvailability

    /// Whether responses are evaluated. Derived once at init.
    private let isEvaluationEnabled: Bool

    // Capped ring-buffer of the last 20 operations.
    private var diagnosticLog: [DiagnosticEntry] = []
    private let maxLogEntries = 20

    public init(
        config: FoundationModelsKitConfiguration,
        router: ModelRouter,
        store: ConversationStore,
        evaluation: EvaluationSuite,
        regional: RegionalAvailability
    ) {
        self.config = config
        self.router = router
        self.store = store
        self.evaluation = evaluation
        self.regional = regional

        // The suite decides which metrics run; config only decides whether.
        self.isEvaluationEnabled = !config.evaluationMetrics.isEmpty
    }

    // MARK: - Primary API

    /// Routes `request`, evaluates the response against the configured metrics,
    /// and stores both turns in the conversation transcript.
    ///
    /// The user turn is stored after a successful response, so a failed request
    /// never leaves a dangling entry in the transcript.
    ///
    /// - Returns: The model response and, when `config.evaluationMetrics` is
    ///   non-empty, an `EvaluationResult`. `nil` when evaluation is disabled.
    public func respond(
        to request: ModelRequest
    ) async throws -> (response: ModelResponse, evaluation: EvaluationResult?) {

        let resolvedTier: ModelTier? = config.regionAwareness
            ? await regional.bestTierFor(region: regional.currentRegion())
            : await router.resolvedTier(for: request)

        // Compact before adding the new turn so the budget check is accurate.
        if config.profile.autoCompact {
            if await store.shouldCompact(maxTokens: config.profile.maxContextTokens) {
                try await store.compact(using: router, maxTokens: config.profile.maxContextTokens)
            }
        }

        let response: ModelResponse
        do {
            response = try await router.routeRequest(request)
        } catch {
            log(request: request, tier: resolvedTier, response: nil, evalResult: nil, error: error)
            throw error
        }

        let evalResult: EvaluationResult? = isEvaluationEnabled
            ? await evaluation.evaluate(response: response, responseID: UUID().uuidString)
            : nil

        // Stored only on success, so a failure leaves no dangling turn.
        await store.addEntry(ConversationEntry(role: "user", content: request.content, toolsUsed: request.tools))
        await store.addEntry(ConversationEntry(role: "assistant", content: response.content))

        log(request: request, tier: resolvedTier, response: response, evalResult: evalResult, error: nil)

        return (response, evalResult)
    }

    // MARK: - Diagnostics

    /// Human-readable summary of the last N operations.
    public func diagnostics() -> String {
        guard !diagnosticLog.isEmpty else { return "No operations recorded." }
        return diagnosticLog.map { $0.formatted() }.joined(separator: "\n\n")
    }

    // MARK: - Transcript forwarding

    /// Full conversation transcript as plain text.
    public func transcript() async -> String {
        await store.transcript()
    }

    /// Number of stored conversation turns.
    public func entryCount() async -> Int {
        await store.entryCount
    }

    /// Writes the conversation transcript to `url` as JSON.
    ///
    /// The file is written in plaintext. Place it somewhere appropriate for the
    /// sensitivity of the conversation — for example a Data Protection–enabled
    /// directory on iOS.
    public func saveTranscript(to url: URL) async throws {
        try await store.save(to: url)
    }

    /// Replaces the conversation transcript with the contents of `url`.
    ///
    /// - Throws: if the file is missing or cannot be decoded.
    public func loadTranscript(from url: URL) async throws {
        try await store.load(from: url)
    }

    /// Clears the conversation transcript, keeping configuration and backends.
    public func clearTranscript() async {
        await store.clear()
    }

    // MARK: - Private helpers

    private func log(
        request: ModelRequest,
        tier: ModelTier?,
        response: ModelResponse?,
        evalResult: EvaluationResult?,
        error: Error?
    ) {
        guard config.loggingEnabled else { return }
        let snip: (String) -> String = { String($0.prefix(80)) }
        let entry = DiagnosticEntry(
            timestamp: Date(),
            requestSnippet: snip(request.content),
            tier: tier,
            responseSnippet: response.map { snip($0.content) } ?? "",
            evaluationPassed: evalResult?.overallPassed,
            errorDescription: error?.localizedDescription
        )
        diagnosticLog.append(entry)
        if diagnosticLog.count > maxLogEntries {
            diagnosticLog.removeFirst(diagnosticLog.count - maxLogEntries)
        }
    }
}
