// SDKIntegration.swift
// Facade that wires ModelRouter, ConversationStore, EvaluationSuite, and
// RegionalAvailability behind a single async entry point.
//
// Callers import FoundationModelsKit, build a FoundationModelsKitConfiguration,
// and interact exclusively with SDKIntegration — the individual actors stay
// hidden behind it.

import Foundation

// MARK: - Configuration

/// Declarative configuration for the entire SDK stack.
/// Serialize to disk or pass via dependency injection.
public struct FoundationModelsKitConfiguration: Sendable, Codable {
    /// Routing and context-management preferences (see DynamicProfileBuilder).
    public var profile: DynamicProfile

    /// Names of built-in metrics to apply to every response.
    /// Valid values: `"NonEmpty"`, `"Length"`, `"ContainsKeywords"`.
    /// Unknown names are silently ignored.
    public var evaluationMetrics: [String]

    /// When `true`, the facade consults `RegionalAvailability` before routing
    /// and may adjust the request's privacy sensitivity to match the region's
    /// best available tier.
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

/// One entry in the in-memory operation log.
private struct DiagnosticEntry: Sendable {
    let timestamp: Date
    let requestSnippet: String  // first 80 chars of request content
    let tier: ModelTier?
    let responseSnippet: String // first 80 chars of response content
    let evaluationPassed: Bool?
    let errorDescription: String?

    func formatted() -> String {
        let ts = ISO8601DateFormatter().string(from: timestamp)
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
        return """
        [\(ts)] tier=\(tierLabel) \(evalLabel)
          req: \(requestSnippet)
          res: \(responseSnippet)
        """
    }
}

// MARK: - Router bridge

/// Thin `LanguageModelProviding` wrapper around `ModelRouter` so it can be
/// passed to APIs that expect the protocol (e.g. `ConversationStore.compact`).
private struct RouterBridge: LanguageModelProviding, Sendable {
    let router: ModelRouter
    func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        try await router.routeRequest(request)
    }
}

// MARK: - Facade

/// Single entry point for the FoundationModelsKit stack.
///
/// `SDKIntegration` orchestrates:
/// 1. Region check (optional)
/// 2. Auto-compaction of the conversation store (if profile enables it)
/// 3. Routing via `ModelRouter`
/// 4. Evaluation via `EvaluationSuite`
/// 5. Appending the turn to `ConversationStore`
/// 6. Diagnostic logging
///
/// Usage — see `IntegrationExample` at the bottom of this file.
public actor SDKIntegration: Sendable {

    private let config: FoundationModelsKitConfiguration
    private let router: ModelRouter
    private let store: ConversationStore
    private let evaluation: EvaluationSuite
    private let regional: RegionalAvailability

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
    }

    // MARK: - Primary API

    /// Routes `request`, optionally evaluates the response, and stores both
    /// turns in the conversation transcript.
    ///
    /// - Returns: The model response and, when evaluation is configured,
    ///   an `EvaluationResult`. The evaluation result is `nil` when
    ///   `config.evaluationMetrics` is empty.
    public func sendMessage(
        _ request: ModelRequest
    ) async throws -> (response: ModelResponse, evaluation: EvaluationResult?) {

        // 1. Optional region-awareness: resolve the current region and log the
        //    best available tier (does not mutate the request for now).
        var resolvedTier: ModelTier? = nil
        if config.regionAwareness {
            let region = await regional.currentRegion()
            resolvedTier = await regional.bestTierFor(region: region)
        }

        // 2. Auto-compact the conversation if the profile requests it and
        //    the transcript is approaching the token budget.
        if config.profile.autoCompact {
            let needsCompact = await store.shouldCompact(maxTokens: config.profile.maxContextTokens)
            if needsCompact {
                // Route compaction through the same router so it obeys the
                // same privacy and tier constraints as regular requests.
                // ConversationStore.compact needs a LanguageModelProviding,
                // so we bridge through the router's on-device model via a thin wrapper.
                try await store.compact(using: RouterBridge(router: router), maxTokens: config.profile.maxContextTokens)
            }
        }

        // 3. Store the user turn before routing so it's present even if the
        //    model call throws.
        await store.addEntry(ConversationEntry(
            role: "user",
            content: request.content,
            toolsUsed: request.tools
        ))

        // 4. Route the request.
        let response: ModelResponse
        do {
            response = try await router.routeRequest(request)
        } catch {
            log(request: request, tier: resolvedTier, response: nil, evalResult: nil, error: error)
            throw error
        }

        // 5. Evaluate the response (nil when no metrics are configured).
        let evalResult: EvaluationResult?
        if !config.evaluationMetrics.isEmpty {
            let id = UUID().uuidString
            evalResult = await evaluation.evaluate(response: response, responseID: id)
        } else {
            evalResult = nil
        }

        // 6. Store the assistant turn.
        await store.addEntry(ConversationEntry(
            role: "assistant",
            content: response.content
        ))

        // 7. Append diagnostic entry.
        log(request: request, tier: resolvedTier, response: response, evalResult: evalResult, error: nil)

        return (response, evalResult)
    }

    // MARK: - Diagnostics

    /// Returns a human-readable summary of the last N operations.
    public func diagnostics() -> String {
        guard !diagnosticLog.isEmpty else { return "No operations recorded." }
        return diagnosticLog.map { $0.formatted() }.joined(separator: "\n\n")
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

        let snippet: (String) -> String = { String($0.prefix(80)) }

        let entry = DiagnosticEntry(
            timestamp: Date(),
            requestSnippet: snippet(request.content),
            tier: tier,
            responseSnippet: response.map { snippet($0.content) } ?? "",
            evaluationPassed: evalResult?.overallPassed,
            errorDescription: error?.localizedDescription
        )

        diagnosticLog.append(entry)
        if diagnosticLog.count > maxLogEntries {
            diagnosticLog.removeFirst(diagnosticLog.count - maxLogEntries)
        }
    }
}

// MARK: - ConversationStore forwarding

// SDKIntegration wraps ConversationStore internally, but callers sometimes
// need to read the transcript directly (e.g. to display history in a UI).
extension SDKIntegration {
    /// Full conversation transcript as plain text.
    public func transcript() async -> String {
        await store.transcript()
    }

    /// Number of stored conversation turns.
    public func entryCount() async -> Int {
        await store.entryCount
    }
}

// MARK: - Integration example

/// Illustrates how to assemble the full stack.
/// This type is intentionally never instantiated — it exists as living
/// documentation that can be copy-pasted into an app's DI layer.
///
/// ```swift
/// // 1. Choose a routing profile.
/// let profile = DynamicProfileBuilder()
///     .withName("myApp")
///     .withRoutingStrategy(.adaptive)
///     .withMaxContextTokens(4096)
///     .withAutoCompact(true)
///     .withPrivacySensitivity(.medium)
///     .build()
///
/// // 2. Wire up backends (replace MockLanguageModel with real conformers).
/// let onDevice = MockLanguageModel()
/// let router   = ModelRouter(onDevice: onDevice)
///
/// // 3. Build supporting actors.
/// let store      = ConversationStore()
/// let suite      = EvaluationSuite(metrics: [NonEmptyMetric(), LengthMetric()])
/// let regional   = RegionalAvailability()
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
///         print("Quality gate failed:", eval.scores.map(\.details))
///     }
/// } catch LanguageModelError.unavailable {
///     print("No model backend is reachable right now.")
/// } catch {
///     print("Unexpected error:", error)
/// }
///
/// // 6. Inspect diagnostics.
/// let report = await sdk.diagnostics()
/// print(report)
/// ```
public enum IntegrationExample {}
