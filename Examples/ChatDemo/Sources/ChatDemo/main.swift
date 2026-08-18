// ChatDemo — shows FoundationModelsKit routing requests by privacy level.
//
// Run:  swift run ChatDemo
//
// Set ANTHROPIC_API_KEY to enable the third-party tier. Without it the demo
// still runs and shows requests being refused escalation — which is the point.

import Foundation
import FoundationModelsKit

// MARK: - Terminal helpers

enum Ansi {
    static let reset  = "\u{001B}[0m"
    static let bold   = "\u{001B}[1m"
    static let dim    = "\u{001B}[2m"
    static let green  = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue   = "\u{001B}[34m"
    static let red    = "\u{001B}[31m"
}

func banner(_ text: String) {
    print("\n\(Ansi.bold)\(text)\(Ansi.reset)")
    print(String(repeating: "─", count: text.count))
}

func tierLabel(_ tier: ModelTier?) -> String {
    switch tier {
    case .onDevice:   return "\(Ansi.green)🔒 on-device\(Ansi.reset)"
    case .pcc:        return "\(Ansi.blue)☁️  private cloud compute\(Ansi.reset)"
    case .thirdParty: return "\(Ansi.yellow)🌐 third-party\(Ansi.reset)"
    case nil:         return "\(Ansi.red)✗ no eligible backend\(Ansi.reset)"
    }
}

// MARK: - Backends

/// Stand-in backends so the demo runs without Apple Intelligence hardware
/// or an API key. Each one reports which tier handled the request.
struct LabelledModel: LanguageModelProviding {
    let tierName: String

    func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        // Simulate work so the streaming demo below is visible.
        try await Task.sleep(for: .milliseconds(150))
        return ModelResponse(
            content: "[handled by \(tierName)] Reply to: \(request.content.prefix(40))…",
            stopReason: "end_turn",
            usage: .estimated(promptChars: request.content.count, completionChars: 60)
        )
    }
}

let onDevice   = LabelledModel(tierName: "on-device")
let pcc        = LabelledModel(tierName: "PCC")
let thirdParty = LabelledModel(tierName: "third-party")

let router = ModelRouter(onDevice: onDevice, pcc: pcc, thirdParty: thirdParty)

// MARK: - 1. Privacy routing

banner("1. Same prompt, three privacy levels")

let longPrompt = String(repeating: "Analyse this quarterly report in depth. ", count: 20)

for sensitivity in [PrivacySensitivity.high, .medium, .low] {
    let request = ModelRequest(
        content: longPrompt,
        privacySensitivity: sensitivity,
        taskComplexity: .complex
    )
    let tier = await router.resolvedTier(for: request)
    let response = try await router.routeRequest(request)

    print("  \(Ansi.bold)\(sensitivity.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))\(Ansi.reset) → \(tierLabel(tier))")
    print("  \(Ansi.dim)\(response.content.prefix(70))\(Ansi.reset)\n")
}

print("\(Ansi.dim)Note: .high stayed on-device despite being large and complex.\(Ansi.reset)")

// MARK: - 2. On-device eligibility

banner("2. Short + simple requests stay on-device even at .low")

let shortRequest = ModelRequest(
    content: "What is 2 + 2?",
    privacySensitivity: .low,
    taskComplexity: .simple
)
let shortTier = await router.resolvedTier(for: shortRequest)
print("  short + simple + .low → \(tierLabel(shortTier))")
print("  \(Ansi.dim)No reason to burn network latency on a trivial prompt.\(Ansi.reset)")

// MARK: - 3. Streaming

banner("3. Streaming")

print("  ", terminator: "")
for try await chunk in router.streamMessage(request: shortRequest) {
    print(chunk, terminator: "")
    fflush(stdout)
}
print()

// MARK: - 4. Retry on transient failure

banner("4. Automatic retry")

actor FlakeyCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}
let counter = FlakeyCounter()

let flakey = MockLanguageModel { _ in
    let attempt = await counter.next()
    if attempt < 3 {
        print("  \(Ansi.red)attempt \(attempt) failed\(Ansi.reset)")
        throw LanguageModelError.unavailable
    }
    print("  \(Ansi.green)attempt \(attempt) succeeded\(Ansi.reset)")
    return ModelResponse(
        content: "Recovered.",
        stopReason: "end_turn",
        usage: TokenUsage(inputTokens: 4, outputTokens: 2)
    )
}

let robust = RetryingLanguageModel(
    wrapped: flakey,
    policy: RetryPolicy(maxAttempts: 3, initialDelay: 0.2, backoffMultiplier: 2)
)
let recovered = try await robust.sendMessage(request: ModelRequest(content: "Hello"))
print("  → \(recovered.content)")

// MARK: - 5. Conversation compaction

banner("5. Conversation compaction")

let store = ConversationStore()
for i in 1...12 {
    await store.addEntry(ConversationEntry(
        role: i.isMultiple(of: 2) ? "assistant" : "user",
        content: "Turn \(i): " + String(repeating: "context ", count: 20)
    ))
}
let before = await store.entryCount
print("  entries before: \(before)")

let summariser = MockLanguageModel { _ in
    ModelResponse(
        content: "• Discussed 12 turns of context\n• Key decisions preserved",
        stopReason: "end_turn",
        usage: TokenUsage(inputTokens: 100, outputTokens: 20)
    )
}
try await store.compact(using: summariser, maxTokens: 100)

let after = await store.entryCount
print("  entries after:  \(after) \(Ansi.dim)(oldest turns summarised, 5 most recent kept)\(Ansi.reset)")

// MARK: - 6. Evaluation

banner("6. Response evaluation")

let suite = EvaluationSuite(metrics: [
    NonEmptyMetric(),
    LengthMetric(min: 10, max: 200),
    ContainsKeywordsMetric(keywords: ["swift"]),
])

let good = ModelResponse(
    content: "Swift makes concurrency safe at compile time.",
    stopReason: "end_turn",
    usage: TokenUsage(inputTokens: 8, outputTokens: 9)
)
let result = await suite.evaluate(response: good, responseID: "demo")

for score in result.scores {
    let mark = score.passed ? "\(Ansi.green)✓\(Ansi.reset)" : "\(Ansi.red)✗\(Ansi.reset)"
    print("  \(mark) \(score.metricName.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%.2f", score.score))")
}
print("  overall: \(result.overallPassed ? "\(Ansi.green)passed\(Ansi.reset)" : "\(Ansi.red)failed\(Ansi.reset)")  avg: \(String(format: "%.2f", result.averageScore))")

print("\n\(Ansi.dim)Source: Examples/ChatDemo/Sources/ChatDemo/main.swift\(Ansi.reset)\n")
