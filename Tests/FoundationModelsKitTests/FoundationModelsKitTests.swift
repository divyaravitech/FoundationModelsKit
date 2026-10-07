import Foundation
import Testing
@testable import FoundationModelsKit

// MARK: - MockLanguageModel

@Test func mockReturnsDefaultResponse() async throws {
    let model = MockLanguageModel()
    let response = try await model.sendMessage(request: ModelRequest(content: "Hello", privacySensitivity: .low, taskComplexity: .simple))
    #expect(response.content == "This is a mock response for testing.")
    #expect(response.stopReason == "end_turn")
    #expect(response.usage.inputTokens == 10)
}

@Test func mockTracksCallCount() async throws {
    let model = MockLanguageModel()
    let req = ModelRequest(content: "Ping")
    _ = try await model.sendMessage(request: req)
    _ = try await model.sendMessage(request: req)
    #expect(await model.callCount == 2)
}

@Test func mockRecordsLastRequest() async throws {
    let model = MockLanguageModel()
    let req = ModelRequest(content: "Sensitive", tools: ["search"], privacySensitivity: .high, taskComplexity: .complex)
    _ = try await model.sendMessage(request: req)
    let last = await model.lastRequest
    #expect(last?.content == "Sensitive")
    #expect(last?.privacySensitivity == .high)
    #expect(last?.tools == ["search"])
}

@Test func mockCustomResponseHandler() async throws {
    let model = MockLanguageModel { _ in
        ModelResponse(content: "Custom", stopReason: "max_tokens", usage: TokenUsage(inputTokens: 5, outputTokens: 3))
    }
    let response = try await model.sendMessage(request: ModelRequest(content: "Hi"))
    #expect(response.content == "Custom")
}

@Test func mockErrorSimulation() async throws {
    let model = MockLanguageModel { _ in throw LanguageModelError.unavailable }
    await #expect(throws: LanguageModelError.unavailable) {
        try await model.sendMessage(request: ModelRequest(content: "Will fail"))
    }
}

@Test func mockResetClearsState() async throws {
    let model = MockLanguageModel()
    _ = try await model.sendMessage(request: ModelRequest(content: "Hi"))
    await model.reset()
    #expect(await model.callCount == 0)
    #expect(await model.lastRequest == nil)
}

// MARK: - TokenUsage

@Test func tokenUsageBillableCalculation() {
    let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cachedInputTokens: 30)
    #expect(usage.billableInputTokens == 70)
}

// MARK: - Codable round-trips

@Test func modelRequestCodableRoundtrip() throws {
    let request = ModelRequest(content: "Test", tools: ["calc"], privacySensitivity: .medium, taskComplexity: .complex)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ModelRequest.self, from: data)
    #expect(decoded == request)
}

@Test func modelResponseCodableRoundtrip() throws {
    let response = ModelResponse(content: "Result", stopReason: "end_turn", usage: TokenUsage(inputTokens: 5, outputTokens: 3))
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
    #expect(decoded == response)
}

// MARK: - Equatable / Hashable

@Test func modelRequestEquatable() {
    let a = ModelRequest(content: "Hello", privacySensitivity: .low, taskComplexity: .simple)
    let b = ModelRequest(content: "Hello", privacySensitivity: .low, taskComplexity: .simple)
    #expect(a == b)
}

@Test func privacySensitivityComparable() {
    #expect(PrivacySensitivity.low < .medium)
    #expect(PrivacySensitivity.medium < .high)
}

@Test func taskComplexityComparable() {
    #expect(TaskComplexity.simple < .medium)
    #expect(TaskComplexity.medium < .complex)
}

// MARK: - Streaming (default implementation)

@Test func streamingDefaultImplementation() async throws {
    let model = MockLanguageModel()
    var chunks: [String] = []
    for try await chunk in model.streamMessage(request: ModelRequest(content: "Hi")) {
        chunks.append(chunk)
    }
    #expect(chunks == ["This is a mock response for testing."])
}

// MARK: - ModelRouter

@Test func routerSendsHighPrivacyToOnDevice() async throws {
    let onDevice = MockLanguageModel()
    let pcc = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice, pcc: pcc)

    // High privacy + large content must still go on-device
    let request = ModelRequest(
        content: String(repeating: "x", count: 1000),
        privacySensitivity: .high,
        taskComplexity: .complex
    )
    _ = try await router.routeRequest(request)
    #expect(await onDevice.callCount == 1)
    #expect(await pcc.callCount == 0)
}

@Test func routerSendsMediumPrivacyLargeRequestToPCC() async throws {
    let onDevice = MockLanguageModel()
    let pcc = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice, pcc: pcc)

    let request = ModelRequest(
        content: String(repeating: "x", count: 1000),
        privacySensitivity: .medium,
        taskComplexity: .complex
    )
    _ = try await router.routeRequest(request)
    #expect(await onDevice.callCount == 0)
    #expect(await pcc.callCount == 1)
}

@Test func routerSendsSmallSimpleLowToOnDevice() async throws {
    let onDevice = MockLanguageModel()
    let thirdParty = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice, thirdParty: thirdParty)

    let request = ModelRequest(content: "Hi", privacySensitivity: .low, taskComplexity: .simple)
    _ = try await router.routeRequest(request)
    #expect(await onDevice.callCount == 1)
    #expect(await thirdParty.callCount == 0)
}

@Test func routerFallsBackToThirdPartyWhenPCCAbsent() async throws {
    let onDevice = MockLanguageModel()
    let thirdParty = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice, thirdParty: thirdParty)

    let request = ModelRequest(
        content: String(repeating: "x", count: 1000),
        privacySensitivity: .low,
        taskComplexity: .complex
    )
    _ = try await router.routeRequest(request)
    #expect(await thirdParty.callCount == 1)
}

@Test func routerThrowsWhenNoBackendAvailableForLowPrivacy() async throws {
    let onDevice = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice) // no pcc, no thirdParty

    let request = ModelRequest(
        content: String(repeating: "x", count: 1000),
        privacySensitivity: .low,
        taskComplexity: .complex
    )
    await #expect(throws: LanguageModelError.unavailable) {
        try await router.routeRequest(request)
    }
}

@Test func routerResolvedTierReturnsNilWhenUnavailable() async {
    let onDevice = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice)
    let request = ModelRequest(
        content: String(repeating: "x", count: 1000),
        privacySensitivity: .low,
        taskComplexity: .complex
    )
    let tier = await router.resolvedTier(for: request)
    #expect(tier == nil)
}

// MARK: - ConversationStore

@Test func conversationStoreAddsAndCounts() async {
    let store = ConversationStore()
    await store.addEntry(ConversationEntry(role: "user", content: "Hello"))
    await store.addEntry(ConversationEntry(role: "assistant", content: "Hi there"))
    #expect(await store.entryCount == 2)
}

@Test func conversationStoreTranscriptFormat() async {
    let store = ConversationStore()
    await store.addEntry(ConversationEntry(role: "user", content: "Hello"))
    await store.addEntry(ConversationEntry(role: "assistant", content: "Hi"))
    let transcript = await store.transcript()
    #expect(transcript.contains("[user] Hello"))
    #expect(transcript.contains("[assistant] Hi"))
}

@Test func conversationStoreShouldCompact() async {
    let store = ConversationStore()
    // Each entry is 100 chars; 3 entries = 300 chars → exceeds 10 tokens * 4 = 40 chars
    for i in 0..<3 {
        await store.addEntry(ConversationEntry(role: "user", content: String(repeating: "x", count: 100)))
        _ = i
    }
    #expect(await store.shouldCompact(maxTokens: 10) == true)
    #expect(await store.shouldCompact(maxTokens: 10000) == false)
}

@Test func conversationStoreCompacts() async throws {
    let store = ConversationStore()
    for i in 0..<10 {
        await store.addEntry(ConversationEntry(role: "user", content: "Message \(i) " + String(repeating: "x", count: 50)))
    }
    let before = await store.entryCount
    let model = MockLanguageModel { _ in
        ModelResponse(content: "• Key point 1\n• Key point 2", stopReason: "end_turn",
                      usage: TokenUsage(inputTokens: 10, outputTokens: 10))
    }
    try await store.compact(using: model, maxTokens: 100)
    let after = await store.entryCount
    #expect(after < before)
    let transcript = await store.transcript()
    #expect(transcript.contains("[COMPACTED SUMMARY]"))
}

@Test func conversationStorePersistence() async throws {
    let store = ConversationStore()
    await store.addEntry(ConversationEntry(role: "user", content: "Saved message"))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-store-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try await store.save(to: url)

    let restored = ConversationStore()
    try await restored.load(from: url)
    #expect(await restored.entryCount == 1)
    let transcript = await restored.transcript()
    #expect(transcript.contains("Saved message"))
}

@Test func conversationStoreClear() async {
    let store = ConversationStore()
    await store.addEntry(ConversationEntry(role: "user", content: "Hello"))
    await store.clear()
    #expect(await store.entryCount == 0)
}

// MARK: - EvaluationSuite

@Test func nonEmptyMetricPasses() async {
    let score = await NonEmptyMetric().evaluate(response: ModelResponse(content: "Hello", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1)))
    #expect(score.passed)
    #expect(score.score == 1.0)
}

@Test func nonEmptyMetricFails() async {
    let score = await NonEmptyMetric().evaluate(response: ModelResponse(content: "   ", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1)))
    #expect(!score.passed)
    #expect(score.score == 0.0)
}

@Test func lengthMetricBoundaryScoresOne() async {
    let metric = LengthMetric(min: 5, max: 50)
    let atMin = await metric.evaluate(response: ModelResponse(content: "Hello", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1)))
    #expect(atMin.passed)
    #expect(atMin.score == 1.0)
}

@Test func lengthMetricOutsideRangeScoresBelow1() async {
    let metric = LengthMetric(min: 100, max: 200)
    let score = await metric.evaluate(response: ModelResponse(content: "Short", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1)))
    #expect(!score.passed)
    #expect(score.score < 1.0)
}

@Test func keywordsMetricAllFound() async {
    let metric = ContainsKeywordsMetric(keywords: ["swift", "apple"])
    let score = await metric.evaluate(response: ModelResponse(content: "Swift is made by Apple", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1)))
    #expect(score.passed)
    #expect(score.score == 1.0)
}

@Test func keywordsMetricPartialCredit() async {
    let metric = ContainsKeywordsMetric(keywords: ["swift", "apple", "xcode"])
    let score = await metric.evaluate(response: ModelResponse(content: "Swift is made by Apple", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1)))
    #expect(!score.passed)
    #expect(score.score > 0.0 && score.score < 1.0)
}

@Test func evaluationSuiteRunsConcurrently() async {
    let suite = EvaluationSuite(metrics: [NonEmptyMetric(), LengthMetric(), ContainsKeywordsMetric(keywords: ["test"])])
    let response = ModelResponse(content: "This is a test response", stopReason: "end_turn", usage: .init(inputTokens: 5, outputTokens: 5))
    let result = await suite.evaluate(response: response, responseID: "r1")
    #expect(result.scores.count == 3)
    #expect(result.overallPassed)
    #expect(result.averageScore > 0)
}

@Test func evaluationSuiteBatchPreservesOrder() async {
    let suite = EvaluationSuite(metrics: [NonEmptyMetric()])
    let responses = (0..<5).map { i in
        ModelResponse(content: "Response \(i)", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1))
    }
    let results = await suite.evaluateBatch(responses: responses)
    #expect(results.count == 5)
    for (i, result) in results.enumerated() {
        #expect(result.responseID == "response-\(i)")
    }
}

// MARK: - RetryPolicy

/// Thread-safe attempt counter for concurrency-safe test closures.
actor AttemptCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

@Test func retryPolicyRetriesOnUnavailable() async throws {
    let counter = AttemptCounter()
    let model = MockLanguageModel { _ in
        let attempt = await counter.increment()
        if attempt < 3 { throw LanguageModelError.unavailable }
        return ModelResponse(content: "OK", stopReason: "end_turn", usage: .init(inputTokens: 1, outputTokens: 1))
    }
    let retrying = RetryingLanguageModel(
        wrapped: model,
        policy: RetryPolicy(maxAttempts: 3, initialDelay: 0, backoffMultiplier: 1, maxDelay: 0)
    )
    let response = try await retrying.sendMessage(request: ModelRequest(content: "Hi"))
    #expect(response.content == "OK")
    #expect(await counter.count == 3)
}

@Test func retryPolicyGivesUpAfterMaxAttempts() async {
    let model = MockLanguageModel { _ in throw LanguageModelError.unavailable }
    let retrying = RetryingLanguageModel(
        wrapped: model,
        policy: RetryPolicy(maxAttempts: 2, initialDelay: 0, backoffMultiplier: 1, maxDelay: 0)
    )
    await #expect(throws: LanguageModelError.unavailable) {
        try await retrying.sendMessage(request: ModelRequest(content: "Hi"))
    }
    #expect(await model.callCount == 2)
}

// MARK: - RegionalAvailability

@Test func regionalAvailabilityFallsBackToGlobal() async {
    let registry = RegionalAvailability()
    // Remove all region-specific records; only global should remain
    let availability = await registry.availability(for: .usEast)
    #expect(availability != nil)
}

@Test func regionalBestTierPrefersPCCOverThirdParty() async {
    let record = ModelAvailability(region: .usEast, onDeviceAvailable: true, pccAvailable: true, thirdPartyAvailable: true)
    let registry = RegionalAvailability(availabilities: [record])
    let tier = await registry.bestTierFor(region: .usEast)
    #expect(tier == .pcc)
}

@Test func regionalBestRemoteTierExcludesOnDevice() async {
    let record = ModelAvailability(region: .apac, onDeviceAvailable: true, pccAvailable: false, thirdPartyAvailable: true)
    let registry = RegionalAvailability(availabilities: [record])
    let remote = await registry.bestRemoteTierFor(region: .apac)
    #expect(remote == .thirdParty)
}

@Test func regionalUpdateAvailabilityMutates() async {
    let registry = RegionalAvailability()
    var updated = ModelAvailability.defaults[.global]!
    updated.thirdPartyAvailable = false
    await registry.updateAvailability(updated)
    let after = await registry.availability(for: .global)
    #expect(after?.thirdPartyAvailable == false)
}

// MARK: - SDKIntegration

/// Builds a facade wired to a single mock backend.
private func makeSDK(
    handler: (@Sendable (ModelRequest) async throws -> ModelResponse)? = nil,
    metrics: [String] = ["NonEmpty"]
) -> (sdk: SDKIntegration, backend: MockLanguageModel) {
    let backend = MockLanguageModel(responseHandler: handler)
    let sdk = SDKIntegration(
        config: FoundationModelsKitConfiguration(
            profile: .balanced,
            evaluationMetrics: metrics,
            regionAwareness: false,
            loggingEnabled: true
        ),
        router: ModelRouter(onDevice: backend),
        store: ConversationStore(),
        evaluation: EvaluationSuite(metrics: [NonEmptyMetric()]),
        regional: RegionalAvailability()
    )
    return (sdk, backend)
}

@Test func sdkStoresBothTurnsOnSuccess() async throws {
    let (sdk, _) = makeSDK()
    _ = try await sdk.sendMessage(
        ModelRequest(content: "Hello", privacySensitivity: .high, taskComplexity: .simple)
    )
    // One user turn plus one assistant turn.
    #expect(await sdk.entryCount() == 2)
}

@Test func sdkLeavesNoDanglingEntryWhenRoutingFails() async {
    let (sdk, _) = makeSDK(handler: { _ in throw LanguageModelError.unavailable })

    await #expect(throws: LanguageModelError.unavailable) {
        try await sdk.sendMessage(
            ModelRequest(content: "Will fail", privacySensitivity: .high, taskComplexity: .simple)
        )
    }
    // A failed request must not leave a half-written transcript, otherwise a
    // retry would duplicate the user's message.
    #expect(await sdk.entryCount() == 0)
}

@Test func sdkRetryAfterFailureDoesNotDuplicateUserTurn() async throws {
    actor Gate {
        private var failed = false
        func shouldFail() -> Bool {
            if failed { return false }
            failed = true
            return true
        }
    }
    let gate = Gate()
    let (sdk, _) = makeSDK(handler: { _ in
        if await gate.shouldFail() { throw LanguageModelError.unavailable }
        return ModelResponse(content: "OK", stopReason: "end_turn",
                             usage: TokenUsage(inputTokens: 1, outputTokens: 1))
    })

    let request = ModelRequest(content: "Same message", privacySensitivity: .high, taskComplexity: .simple)
    _ = try? await sdk.sendMessage(request)
    _ = try await sdk.sendMessage(request)

    #expect(await sdk.entryCount() == 2)
    let transcript = await sdk.transcript()
    // "Same message" should appear exactly once.
    #expect(transcript.components(separatedBy: "Same message").count - 1 == 1)
}

@Test func sdkReturnsEvaluationWhenMetricsConfigured() async throws {
    let (sdk, _) = makeSDK(metrics: ["NonEmpty"])
    let (_, evaluation) = try await sdk.sendMessage(
        ModelRequest(content: "Hi", privacySensitivity: .high, taskComplexity: .simple)
    )
    #expect(evaluation != nil)
    #expect(evaluation?.overallPassed == true)
}

@Test func sdkSkipsEvaluationWhenNoMetricsConfigured() async throws {
    let (sdk, _) = makeSDK(metrics: [])
    let (_, evaluation) = try await sdk.sendMessage(
        ModelRequest(content: "Hi", privacySensitivity: .high, taskComplexity: .simple)
    )
    #expect(evaluation == nil)
}

/// A metric that exists only in this test — it cannot be named in
/// `evaluationMetrics`, so it can only reach the SDK via the injected suite.
private struct SentinelMetric: EvaluationMetric, Sendable {
    let name = "Sentinel"
    func evaluate(response: ModelResponse) async -> EvaluationScore {
        EvaluationScore(metricName: name, score: 1.0, passed: true, details: "sentinel ran")
    }
}

@Test func sdkRunsTheInjectedSuiteNotTheConfigNames() async throws {
    // Regression: the facade used to resolve `evaluationMetrics` against a
    // table of built-ins and discard the injected suite, so custom metrics
    // silently never ran.
    let sdk = SDKIntegration(
        config: FoundationModelsKitConfiguration(
            profile: .balanced,
            evaluationMetrics: ["Sentinel"],
            regionAwareness: false,
            loggingEnabled: true
        ),
        router: ModelRouter(onDevice: MockLanguageModel()),
        store: ConversationStore(),
        evaluation: EvaluationSuite(metrics: [SentinelMetric()]),
        regional: RegionalAvailability()
    )

    let (_, evaluation) = try await sdk.sendMessage(
        ModelRequest(content: "Hi", privacySensitivity: .high, taskComplexity: .simple)
    )

    let names = try #require(evaluation?.scores.map(\.metricName))
    #expect(names == ["Sentinel"])
    #expect(evaluation?.scores.first?.details == "sentinel ran")
}

@Test func sdkDiagnosticsRecordOperations() async throws {
    let (sdk, _) = makeSDK()
    _ = try await sdk.sendMessage(
        ModelRequest(content: "Hello", privacySensitivity: .high, taskComplexity: .simple)
    )
    let report = await sdk.diagnostics()
    #expect(report.contains("tier=\(ModelTier.onDevice.rawValue)"))
    #expect(!report.contains("No operations recorded"))
}

@Test func sdkDiagnosticsRecordFailures() async {
    let (sdk, _) = makeSDK(handler: { _ in throw LanguageModelError.unavailable })
    _ = try? await sdk.sendMessage(
        ModelRequest(content: "Nope", privacySensitivity: .high, taskComplexity: .simple)
    )
    let report = await sdk.diagnostics()
    #expect(report.contains("ERROR"))
}

@Test func sdkTranscriptPersistenceRoundtrip() async throws {
    let (sdk, _) = makeSDK()
    _ = try await sdk.sendMessage(
        ModelRequest(content: "Persist me", privacySensitivity: .high, taskComplexity: .simple)
    )

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sdk-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try await sdk.saveTranscript(to: url)

    let (restored, _) = makeSDK()
    try await restored.loadTranscript(from: url)

    #expect(await restored.entryCount() == 2)
    #expect(await restored.transcript().contains("Persist me"))
}

@Test func sdkClearTranscriptEmptiesStore() async throws {
    let (sdk, _) = makeSDK()
    _ = try await sdk.sendMessage(
        ModelRequest(content: "Hello", privacySensitivity: .high, taskComplexity: .simple)
    )
    await sdk.clearTranscript()
    #expect(await sdk.entryCount() == 0)
}

@Test func sdkHighSensitivityNeverLeavesDevice() async throws {
    let onDevice = MockLanguageModel()
    let pcc = MockLanguageModel()
    let thirdParty = MockLanguageModel()

    let sdk = SDKIntegration(
        config: FoundationModelsKitConfiguration(
            profile: .cloudFirst,          // deliberately biased toward the cloud
            evaluationMetrics: [],
            regionAwareness: false,
            loggingEnabled: false
        ),
        router: ModelRouter(onDevice: onDevice, pcc: pcc, thirdParty: thirdParty),
        store: ConversationStore(),
        evaluation: EvaluationSuite(metrics: []),
        regional: RegionalAvailability()
    )

    // Large and complex — every heuristic argues for escalation.
    _ = try await sdk.sendMessage(ModelRequest(
        content: String(repeating: "sensitive ", count: 200),
        privacySensitivity: .high,
        taskComplexity: .complex
    ))

    #expect(await onDevice.callCount == 1)
    #expect(await pcc.callCount == 0)
    #expect(await thirdParty.callCount == 0)
}

// MARK: - TokenUsage Codable resilience

@Test func tokenUsageDecodesJSONMissingNewerFields() throws {
    // Regression: synthesized Codable ignores property defaults and throws
    // `keyNotFound`, which made every previously-saved transcript undecodable
    // the moment a field was added.
    let legacy = #"{"inputTokens":10,"outputTokens":5}"#.data(using: .utf8)!
    let usage = try JSONDecoder().decode(TokenUsage.self, from: legacy)
    #expect(usage.inputTokens == 10)
    #expect(usage.outputTokens == 5)
    #expect(usage.cachedInputTokens == 0)
    #expect(usage.isEstimated == false)
}

@Test func tokenUsageRoundTripsIsEstimated() throws {
    let usage = TokenUsage.estimated(promptChars: 400, completionChars: 80)
    #expect(usage.isEstimated)
    let decoded = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(usage))
    #expect(decoded == usage)
    #expect(decoded.isEstimated)
}

@Test func tokenUsageEstimatedIsNeverZero() {
    // A short prompt must not report 0 tokens — downstream budget maths
    // divides by these values.
    let usage = TokenUsage.estimated(promptChars: 1, completionChars: 1)
    #expect(usage.inputTokens >= 1)
    #expect(usage.outputTokens >= 1)
}

// MARK: - Stream cancellation

@Test func streamCancellationStopsUpstreamWork() async throws {
    // A consumer that breaks early must not leave the backend running.
    actor Counter {
        private(set) var chunks = 0
        func bump() { chunks += 1 }
    }
    let counter = Counter()

    struct EndlessModel: LanguageModelProviding, Sendable {
        let counter: Counter
        func sendMessage(request: ModelRequest) async throws -> ModelResponse {
            ModelResponse(content: "", stopReason: "end_turn",
                          usage: TokenUsage(inputTokens: 1, outputTokens: 1))
        }
        func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    while !Task.isCancelled {
                        await counter.bump()
                        continuation.yield("chunk")
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    let model = EndlessModel(counter: counter)
    var received = 0
    for try await _ in model.streamMessage(request: ModelRequest(content: "go")) {
        received += 1
        if received == 3 { break }
    }

    let atBreak = await counter.chunks
    try await Task.sleep(for: .milliseconds(100))
    let afterWait = await counter.chunks

    // Production must have stopped; allow one in-flight iteration to land.
    #expect(afterWait - atBreak <= 1, "stream kept producing after the consumer stopped")
}

@Test func retryingModelDoesNotReplayAlreadyYieldedChunks() async throws {
    // Retrying a stream that already emitted would duplicate partial output.
    actor Attempts {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
    }
    let attempts = Attempts()

    struct FailsMidStream: LanguageModelProviding, Sendable {
        let attempts: Attempts
        func sendMessage(request: ModelRequest) async throws -> ModelResponse {
            throw LanguageModelError.unavailable
        }
        func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    _ = await attempts.next()
                    continuation.yield("Hello wor")
                    continuation.finish(throwing: LanguageModelError.unavailable)
                }
            }
        }
    }

    let retrying = RetryingLanguageModel(
        wrapped: FailsMidStream(attempts: attempts),
        policy: RetryPolicy(maxAttempts: 3, initialDelay: 0, backoffMultiplier: 1, maxDelay: 0)
    )

    var chunks: [String] = []
    await #expect(throws: LanguageModelError.unavailable) {
        for try await chunk in retrying.streamMessage(request: ModelRequest(content: "hi")) {
            chunks.append(chunk)
        }
    }

    #expect(chunks == ["Hello wor"], "partial output was replayed")
    #expect(await attempts.count == 1, "a stream that already emitted must not be retried")
}

// MARK: - DynamicProfileBuilder

@Test func profileBuilderDefaults() {
    let profile = DynamicProfileBuilder().build()
    #expect(profile.name == "default")
    #expect(profile.routingStrategy == .adaptive)
    #expect(profile.maxContextTokens == 4096)
    #expect(profile.autoCompact)
    #expect(profile.privacySensitivity == .medium)
}

@Test func profileBuilderChainsAndIsValueSemantic() {
    let base = DynamicProfileBuilder().withName("base")
    let a = base.withMaxContextTokens(1024).build()
    let b = base.withMaxContextTokens(8192).build()

    // Each `with` returns a copy — branching off `base` must not alias.
    #expect(a.maxContextTokens == 1024)
    #expect(b.maxContextTokens == 8192)
    #expect(a.name == "base" && b.name == "base")
}

@Test func prebuiltProfilesHonourTheirPrivacyIntent() {
    #expect(DynamicProfile.onDeviceOnly.routingStrategy == .preferOnDevice)
    #expect(DynamicProfile.onDeviceOnly.privacySensitivity == .high)
    #expect(DynamicProfile.cloudFirst.privacySensitivity == .low)
    #expect(DynamicProfile.balanced.autoCompact)
}

@Test func profileCodableRoundtrip() throws {
    let profile = DynamicProfileBuilder().withName("x").withRoutingStrategy(.preferPCC).build()
    let decoded = try JSONDecoder().decode(
        DynamicProfile.self, from: JSONEncoder().encode(profile)
    )
    #expect(decoded.name == "x")
    #expect(decoded.routingStrategy == .preferPCC)
}

// MARK: - AnthropicLanguageModel

@Test func anthropicConfigurationRedactsAPIKeyFromDescription() {
    let config = AnthropicConfiguration(apiKey: "sk-ant-SUPERSECRET-value")
    let rendered = "\(config)" + String(reflecting: config)
    #expect(!rendered.contains("SUPERSECRET"), "API key leaked via string conversion")
    #expect(rendered.contains("redacted"))
}

@Test func anthropicConfigurationDefaultModelIsNotDateSuffixed() {
    // Anthropic model IDs are complete as-is; a date suffix is a fabricated ID
    // that fails at request time.
    let model = AnthropicConfiguration(apiKey: "k").model
    #expect(!model.contains("-2025"))
    #expect(!model.contains("-2026"))
    #expect(model == "claude-opus-5-5")
}

@Test func anthropicSurfacesHTTPErrorsAsTypedErrors() async throws {
    // 529 (overloaded) must map to `.unavailable` so RetryingLanguageModel
    // retries it; other 4xx must not be silently retried.
    #expect(LanguageModelError.unavailable == LanguageModelError.unavailable)
    let policy = RetryPolicy.default
    #expect(policy.shouldRetry(LanguageModelError.unavailable))
    #expect(!policy.shouldRetry(LanguageModelError.contextWindowExceeded))
    #expect(!policy.shouldRetry(AnthropicError.apiError(statusCode: 400, body: "bad")))
}

// MARK: - OnDeviceLanguageModel

@Test func onDeviceReportsAvailabilityWithoutCrashing() {
    // Must answer on every platform, including those without FoundationModels.
    _ = OnDeviceLanguageModel.isAvailable
}

@Test func onDeviceThrowsUnavailableWhenFrameworkAbsent() async throws {
    // On a machine without Apple Intelligence this is the contract callers
    // rely on to fall back; it must be a typed error, not a crash.
    let model = OnDeviceLanguageModel()
    guard !OnDeviceLanguageModel.isAvailable else { return }  // real hardware: skip
    await #expect(throws: LanguageModelError.unavailable) {
        try await model.sendMessage(request: ModelRequest(content: "hi"))
    }
}

@Test func transientHTTPStatusesAreRetryable() {
    // 429 and 5xx must map to .unavailable so RetryingLanguageModel backs off.
    // An earlier version mapped only 529, so rate limits failed outright.
    for code in [408, 429, 500, 502, 503, 529] {
        #expect(AnthropicLanguageModel.isTransient(statusCode: code), "\(code) should be retryable")
    }
    for code in [400, 401, 403, 404, 422] {
        #expect(!AnthropicLanguageModel.isTransient(statusCode: code), "\(code) must not be retried")
    }
}

@Test func routerOnDeviceLimitIsRespected() async throws {
    let onDevice = MockLanguageModel()
    let pcc = MockLanguageModel()
    let router = ModelRouter(onDevice: onDevice, pcc: pcc)

    let justUnder = String(repeating: "x", count: ModelRouter.onDeviceCharacterLimit - 1)
    _ = try await router.routeRequest(
        ModelRequest(content: justUnder, privacySensitivity: .low, taskComplexity: .simple)
    )
    #expect(await onDevice.callCount == 1)

    let atLimit = String(repeating: "x", count: ModelRouter.onDeviceCharacterLimit)
    _ = try await router.routeRequest(
        ModelRequest(content: atLimit, privacySensitivity: .low, taskComplexity: .simple)
    )
    #expect(await pcc.callCount == 1, "a prompt at the limit should escalate")
}

// MARK: - Token estimation

@Test func heuristicEstimatorBeatsFixedRatioOnCJK() {
    let estimator = HeuristicTokenEstimator()
    let japanese = "これは日本語のテキストです"
    // ~1 token per CJK character; a 4-chars-per-token rule reports a quarter of that.
    #expect(estimator.tokenCount(of: japanese) >= japanese.count - 2)
    #expect(estimator.tokenCount(of: japanese) > FixedRatioTokenEstimator().tokenCount(of: japanese))
}

@Test func heuristicEstimatorHandlesProseAndEmpty() {
    let estimator = HeuristicTokenEstimator()
    #expect(estimator.tokenCount(of: "") == 0)
    let prose = String(repeating: "the quick brown fox ", count: 10)  // 200 chars
    let count = estimator.tokenCount(of: prose)
    #expect(count > 20 && count < 80, "English prose estimate out of range: \(count)")
}

@Test func storeUsesInjectedEstimator() async {
    struct AlwaysTen: TokenEstimating {
        func tokenCount(of text: String) -> Int { 10 }
    }
    let store = ConversationStore(estimator: AlwaysTen())
    await store.addEntry(ConversationEntry(role: "user", content: "x"))
    await store.addEntry(ConversationEntry(role: "user", content: "y"))
    #expect(await store.estimatedTokenCount() == 20)
    #expect(await store.shouldCompact(maxTokens: 19))
    #expect(!(await store.shouldCompact(maxTokens: 20)))
}

// MARK: - ConversationStore search

@Test func storeSearchFiltersAndExcludesSummaries() async {
    let store = ConversationStore()
    await store.addEntry(ConversationEntry(role: "user", content: "Where is the invoice?"))
    await store.addEntry(ConversationEntry(role: "assistant", content: "In the Finance folder."))
    await store.addEntry(ConversationEntry(
        role: "assistant",
        content: "\(ConversationStore.summaryPrefix) discussed the invoice"
    ))

    #expect(await store.search("invoice").count == 1)
    #expect(await store.search("invoice", includingSummaries: true).count == 2)
    #expect(await store.search("INVOICE").count == 1)
    #expect(await store.search("INVOICE", caseSensitive: true).isEmpty)
    #expect(await store.search("").isEmpty)
}

@Test func storeFiltersByRoleAndRecency() async {
    let store = ConversationStore()
    let cutoff = Date()
    // Explicit timestamps: `Date()` can land on the same instant as `cutoff`.
    await store.addEntry(ConversationEntry(role: "user", content: "a", timestamp: cutoff.addingTimeInterval(-60)))
    await store.addEntry(ConversationEntry(role: "assistant", content: "b", timestamp: cutoff.addingTimeInterval(10)))
    await store.addEntry(ConversationEntry(role: "user", content: "c", timestamp: cutoff.addingTimeInterval(20)))

    #expect(await store.entries(withRole: "user").count == 2)
    #expect(await store.entries(after: cutoff).count == 2)
    #expect(await store.recentEntries(2).map(\.content) == ["b", "c"])
    #expect(await store.recentEntries(0).isEmpty)
    #expect(await store.entries(matching: { $0.content == "b" }).count == 1)
}

// MARK: - JSONValue

@Test func jsonValueRoundTripsThroughFoundation() throws {
    let value = JSONValue.object([
        "city": .string("Berlin"),
        "days": .number(3),
        "exact": .bool(true),
        "tags": .array([.string("a"), .null]),
    ])
    let data = try JSONSerialization.data(withJSONObject: value.foundationValue)
    #expect(try JSONValue.decode(data) == value)
}

@Test func jsonValueSubscriptReadsStrings() {
    let value = JSONValue.object(["city": .string("Oslo")])
    #expect(value["city"]?.stringValue == "Oslo")
    #expect(value["missing"] == nil)
}

@Test func jsonValueDistinguishesBoolFromNumber() throws {
    let data = #"{"flag":true,"count":1}"#.data(using: .utf8)!
    let value = try JSONValue.decode(data)
    #expect(value["flag"] == .bool(true))
    #expect(value["count"] == .number(1))
}

// MARK: - Tools

private struct EchoTool: Tool {
    let name = "echo"
    let description = "Echoes the text back."
    let parameterSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
    ])
    func call(arguments: JSONValue) async throws -> String {
        guard let text = arguments["text"]?.stringValue else {
            throw ToolError.invalidArguments("text is required")
        }
        return text.uppercased()
    }
}

@Test func toolRegistryRunsRegisteredTool() async throws {
    let registry = ToolRegistry([EchoTool()])
    let result = try await registry.run(
        ToolCall(id: "1", name: "echo", arguments: .object(["text": .string("hi")]))
    )
    #expect(result == "HI")
    #expect(registry.names == ["echo"])
}

@Test func toolRegistryRejectsUnknownTool() async {
    let registry = ToolRegistry([EchoTool()])
    await #expect(throws: LanguageModelError.toolNotSupported("nope")) {
        try await registry.run(ToolCall(id: "1", name: "nope", arguments: .null))
    }
}

@Test func toolSurfacesInvalidArguments() async {
    let registry = ToolRegistry([EchoTool()])
    await #expect(throws: ToolError.invalidArguments("text is required")) {
        try await registry.run(ToolCall(id: "1", name: "echo", arguments: .object([:])))
    }
}

@Test func emptyRegistryReportsEmpty() {
    #expect(ToolRegistry([]).isEmpty)
    #expect(!ToolRegistry([EchoTool()]).isEmpty)
}

// MARK: - OpenAI backend

@Test func openAIConfigurationRedactsKeyAndDefaultsSensibly() {
    let config = OpenAIConfiguration(apiKey: "sk-SUPERSECRET")
    #expect(!"\(config)".contains("SUPERSECRET"))
    #expect(config.model == OpenAIConfiguration.defaultModel)
}

@Test func openAITransientClassificationMatchesAnthropic() {
    for code in [408, 429, 500, 503] {
        #expect(OpenAILanguageModel.isTransient(statusCode: code))
    }
    for code in [400, 401, 404] {
        #expect(!OpenAILanguageModel.isTransient(statusCode: code))
    }
}

// MARK: - On-device, against real hardware when present

@Test func onDeviceProducesRealCompletionWhenAvailable() async throws {
    guard OnDeviceLanguageModel.isAvailable else { return }

    let model = OnDeviceLanguageModel()
    let response = try await model.sendMessage(
        request: ModelRequest(content: "Reply with exactly: OK", privacySensitivity: .high)
    )
    #expect(!response.content.isEmpty)
    #expect(response.usage.isEstimated, "on-device counts are estimates")
    #expect(response.usage.inputTokens > 0)
}

@Test func onDeviceStreamsRealChunksWhenAvailable() async throws {
    guard OnDeviceLanguageModel.isAvailable else { return }

    let model = OnDeviceLanguageModel()
    var text = ""
    for try await chunk in model.streamMessage(request: ModelRequest(content: "Count to three")) {
        text += chunk
    }
    #expect(!text.isEmpty, "streaming produced nothing")
}

@Test func routerKeepsHighSensitivityOnRealOnDeviceModel() async throws {
    guard OnDeviceLanguageModel.isAvailable else { return }

    let cloud = MockLanguageModel()
    let router = ModelRouter(onDevice: OnDeviceLanguageModel(), pcc: cloud, thirdParty: cloud)

    let response = try await router.routeRequest(
        ModelRequest(
            content: String(repeating: "sensitive record ", count: 50),
            privacySensitivity: .high,
            taskComplexity: .complex
        )
    )
    #expect(!response.content.isEmpty)
    #expect(await cloud.callCount == 0, "high-sensitivity request reached a cloud backend")
}
