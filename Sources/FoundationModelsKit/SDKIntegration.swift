// SDKIntegration.swift
// Facade that wires ModelRouter, ConversationStore, EvaluationSuite, and
// RegionalAvailability behind a single async entry point.

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

// ISO8601DateFormatter is not Sendable, but is safe to read-only share after
// initialisation. Marked nonisolated(unsafe) to satisfy strict concurrency.
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

        // The injected suite decides *which* metrics run; the config field only
        // decides *whether* they run. An earlier version resolved metric names
        // against a built-in table and ignored the injected suite entirely,
        // which silently discarded any custom metric a caller passed in.
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
    public func sendMessage(
        _ request: ModelRequest
    ) async throws -> (response: ModelResponse, evaluation: EvaluationResult?) {

        // 1. Optional region-awareness — derive the best available tier for telemetry.
        let resolvedTier: ModelTier? = config.regionAwareness
            ? await regional.bestTierFor(region: regional.currentRegion())
            : await router.resolvedTier(for: request)

        // 2. Auto-compact before adding the new turn so the budget check is accurate.
        if config.profile.autoCompact {
            if await store.shouldCompact(maxTokens: config.profile.maxContextTokens) {
                // ModelRouter now conforms to LanguageModelProviding directly.
                try await store.compact(using: router, maxTokens: config.profile.maxContextTokens)
            }
        }

        // 3. Route the request. Store turns only on success to prevent dangling entries.
        let response: ModelResponse
        do {
            response = try await router.routeRequest(request)
        } catch {
            log(request: request, tier: resolvedTier, response: nil, evalResult: nil, error: error)
            throw error
        }

        // 4. Evaluate with the injected suite — the caller's metrics, including
        //    any custom ones, which a names-based filter could never express.
        let evalResult: EvaluationResult? = isEvaluationEnabled
            ? await evaluation.evaluate(response: response, responseID: UUID().uuidString)
            : nil

        // 5. Commit both turns to the store now that we have a successful response.
        await store.addEntry(ConversationEntry(role: "user", content: request.content, toolsUsed: request.tools))
        await store.addEntry(ConversationEntry(role: "assistant", content: response.content))

        // 6. Diagnostics.
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

// MARK: - Integration example

/// Living documentation for assembling the full stack.
/// Never instantiated — exists purely so Quick Help and package doc renderers
/// can surface the example inline.
///
/// ```swift
/// // 1. Choose a profile.
/// let profile = DynamicProfileBuilder()
///     .withName("myApp")
///     .withRoutingStrategy(.adaptive)
///     .withMaxContextTokens(4096)
///     .withAutoCompact(true)
///     .withPrivacySensitivity(.medium)
///     .build()
///
/// // 2. Wire backends (swap MockLanguageModel for real conformers in production).
/// let onDevice = MockLanguageModel()
/// let router   = ModelRouter(onDevice: onDevice)
///
/// // 3. Build supporting actors.
/// let store    = ConversationStore()
/// let suite    = EvaluationSuite(metrics: [NonEmptyMetric(), LengthMetric()])
/// let regional = RegionalAvailability()
///
/// // 4. Assemble the facade.
/// let config = FoundationModelsKitConfiguration(
///     profile: profile,
///     evaluationMetrics: ["NonEmpty", "Length"],
///     regionAwareness: true,
///     loggingEnabled: true
/// )
/// let sdk = SDKIntegration(
///     config: config,
///     router: router,
///     store: store,
///     evaluation: suite,
///     regional: regional
/// )
///
/// // 5. Send a message.
/// do {
///     let (response, evalResult) = try await sdk.sendMessage(
///         ModelRequest(content: "Summarise the quarterly report.", privacySensitivity: .high)
///     )
///     print(response.content)
///     if let eval = evalResult, !eval.overallPassed {
///         print("Quality gate failed:", eval.scores.compactMap(\.details))
///     }
/// } catch LanguageModelError.unavailable {
///     print("No backend reachable.")
/// } catch {
///     print("Unexpected error:", error)
/// }
///
/// // 6. Inspect diagnostics.
/// let report = await sdk.diagnostics()
/// print(report)
/// ```
public enum IntegrationExample {}
