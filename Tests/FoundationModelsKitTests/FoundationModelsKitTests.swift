import Foundation
import Testing
@testable import FoundationModelsKit

@Test func mockReturnsDefaultResponse() async throws {
    let model = MockLanguageModel()
    let request = ModelRequest(content: "Hello", privacySensitivity: .low, taskComplexity: .simple)
    let response = try await model.sendMessage(request: request)

    #expect(response.content == "This is a mock response for testing.")
    #expect(response.stopReason == "end_turn")
    #expect(response.usage.inputTokens == 10)
    #expect(response.usage.outputTokens == 8)
    #expect(response.usage.cachedInputTokens == 0)
}

@Test func mockTracksCallCount() async throws {
    let model = MockLanguageModel()
    let request = ModelRequest(content: "Ping")

    _ = try await model.sendMessage(request: request)
    _ = try await model.sendMessage(request: request)

    let count = await model.callCount
    #expect(count == 2)
}

@Test func mockRecordsLastRequest() async throws {
    let model = MockLanguageModel()
    let request = ModelRequest(
        content: "Sensitive query",
        tools: ["search"],
        privacySensitivity: .high,
        taskComplexity: .complex
    )
    _ = try await model.sendMessage(request: request)

    let last = await model.lastRequest
    #expect(last?.content == "Sensitive query")
    #expect(last?.privacySensitivity == .high)
    #expect(last?.taskComplexity == .complex)
    #expect(last?.tools == ["search"])
}

@Test func mockCustomResponseHandler() async throws {
    let model = MockLanguageModel { _ in
        ModelResponse(
            content: "Custom reply",
            stopReason: "max_tokens",
            usage: TokenUsage(inputTokens: 5, outputTokens: 3)
        )
    }
    let response = try await model.sendMessage(request: ModelRequest(content: "Hi"))
    #expect(response.content == "Custom reply")
    #expect(response.stopReason == "max_tokens")
}

@Test func mockErrorSimulation() async throws {
    let model = MockLanguageModel { _ in
        throw LanguageModelError.unavailable
    }
    await #expect(throws: LanguageModelError.unavailable) {
        try await model.sendMessage(request: ModelRequest(content: "Will fail"))
    }
}

@Test func tokenUsageBillableCalculation() {
    let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cachedInputTokens: 30)
    #expect(usage.billableInputTokens == 70)
}

@Test func modelRequestCodableRoundtrip() throws {
    let request = ModelRequest(
        content: "Test prompt",
        tools: ["calculator"],
        privacySensitivity: .medium,
        taskComplexity: .complex
    )
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ModelRequest.self, from: data)

    #expect(decoded.content == request.content)
    #expect(decoded.tools == request.tools)
    #expect(decoded.privacySensitivity == request.privacySensitivity)
    #expect(decoded.taskComplexity == request.taskComplexity)
}

@Test func mockResetClearsState() async throws {
    let model = MockLanguageModel()
    _ = try await model.sendMessage(request: ModelRequest(content: "Hi"))

    await model.reset()

    let count = await model.callCount
    let last = await model.lastRequest
    #expect(count == 0)
    #expect(last == nil)
}
