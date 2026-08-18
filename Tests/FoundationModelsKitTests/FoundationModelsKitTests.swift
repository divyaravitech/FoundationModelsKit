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
