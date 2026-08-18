# FoundationModelsKit

A privacy-first Swift SDK for routing language model requests across on-device (Apple Intelligence), Private Cloud Compute, and third-party backends — with automatic context management, streaming, evaluation, and retries.

[![CI](https://github.com/YOUR_USERNAME/FoundationModelsKit/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_USERNAME/FoundationModelsKit/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2015%20%7C%20iOS%2018%20%7C%20watchOS%2011%20%7C%20tvOS%2018%20%7C%20visionOS%202-blue.svg)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

---

## Why FoundationModelsKit?

Apple's ecosystem now has three tiers of language model inference. Choosing the right one — and switching gracefully when one isn't available — is boilerplate nobody wants to write twice:

| Tier | Backend | Privacy | Capability |
|------|---------|---------|------------|
| On-device | Apple Intelligence (Neural Engine) | 🔒 Data never leaves device | Good for short, simple tasks |
| PCC | Apple Private Cloud Compute | 🔒 Apple-only infrastructure | Better for complex tasks |
| Third-party | Anthropic, OpenAI, etc. | ⚠️ External server | Highest capability |

FoundationModelsKit encodes that policy in one place — the `ModelRouter` — and exposes a single `LanguageModelProviding` protocol so every backend is swappable with one line.

---

## Installation

**Swift Package Manager**

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/YOUR_USERNAME/FoundationModelsKit.git", from: "1.0.0")
]
```

Or add it in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

---

## Quick Start

```swift
import FoundationModelsKit

// 1. Pick a backend
let onDevice = OnDeviceLanguageModel()           // Apple Intelligence
// let cloud = AnthropicLanguageModel(config: AnthropicConfiguration(apiKey: "sk-ant-…"))

// 2. Build a router
let router = ModelRouter(onDevice: onDevice)     // add pcc: / thirdParty: when available

// 3. Send a message
let request = ModelRequest(
    content: "Summarise this meeting note in three bullets.",
    privacySensitivity: .high,    // stays on-device
    taskComplexity: .simple
)

let response = try await router.sendMessage(request: request)
print(response.content)
```

### With streaming

```swift
for try await chunk in router.streamMessage(request: request) {
    print(chunk, terminator: "")
}
```

### With automatic retries

```swift
let robust = RetryingLanguageModel(wrapped: router, policy: .default)
let response = try await robust.sendMessage(request: request)
```

### Full SDK facade (router + conversation + evaluation)

```swift
let sdk = SDKIntegration(
    config: FoundationModelsKitConfiguration(
        profile: .balanced,
        evaluationMetrics: ["NonEmpty", "Length"],
        regionAwareness: true,
        loggingEnabled: true
    ),
    router: router,
    store: ConversationStore(),
    evaluation: EvaluationSuite(metrics: [NonEmptyMetric(), LengthMetric()]),
    regional: RegionalAvailability()
)

let (response, evalResult) = try await sdk.sendMessage(request)

if let eval = evalResult, !eval.overallPassed {
    print("Quality gate failed:", eval.scores.compactMap(\.details))
}

// Persist the conversation
let url = FileManager.default.temporaryDirectory.appendingPathComponent("session.json")
try await sdk.store.save(to: url)
```

---

## Backends

### OnDeviceLanguageModel
Wraps Apple's `FoundationModels` framework. Available on Apple Intelligence-capable devices running macOS 15.1+ / iOS 18.1+.

```swift
// Check availability before instantiating
guard OnDeviceLanguageModel.isAvailable else { /* fallback */ }
let model = OnDeviceLanguageModel()
```

### AnthropicLanguageModel
URLSession-based wrapper for the Anthropic Messages API. No external dependencies.

```swift
let model = AnthropicLanguageModel(
    config: AnthropicConfiguration(
        apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!,
        model: "claude-opus-5-20251101",
        maxTokens: 1024
    )
)
```

### MockLanguageModel
Deterministic test double. Use in unit tests and SwiftUI previews.

```swift
let mock = MockLanguageModel { _ in
    ModelResponse(content: "Fake reply", stopReason: "end_turn",
                  usage: TokenUsage(inputTokens: 5, outputTokens: 3))
}
```

---

## Privacy Routing

The `ModelRouter` enforces data-residency constraints before any other heuristic:

| `privacySensitivity` | Routing rule |
|----------------------|--------------|
| `.high` | On-device **only** — never escalates |
| `.medium` | On-device for small/simple requests; PCC otherwise; never third-party |
| `.low` | Full fallback chain: on-device → PCC → third-party |

---

## Conversation Management

`ConversationStore` tracks the full turn history and automatically compacts it when the context window fills up:

```swift
let store = ConversationStore()
await store.addEntry(ConversationEntry(role: "user", content: "Hello"))

// Auto-compact when approaching the token budget
if await store.shouldCompact(maxTokens: 4096) {
    try await store.compact(using: router, maxTokens: 4096)
}

// Persist across app launches
try await store.save(to: sessionURL)
try await store.load(from: sessionURL)
```

---

## Evaluation

Plug in quality gates that run against every response:

```swift
let suite = EvaluationSuite(metrics: [
    NonEmptyMetric(),
    LengthMetric(min: 20, max: 2000),
    ContainsKeywordsMetric(keywords: ["summary", "action items"]),
    MyCustomMetric(),         // conform to EvaluationMetric
])

let result = await suite.evaluate(response: response, responseID: "turn-1")
print(result.overallPassed, result.averageScore)
```

Custom metric:

```swift
struct ToxicityMetric: EvaluationMetric, Sendable {
    let name = "Toxicity"
    func evaluate(response: ModelResponse) async -> EvaluationScore {
        let safe = !response.content.contains("badword")
        return EvaluationScore(metricName: name, score: safe ? 1.0 : 0.0, passed: safe)
    }
}
```

---

## Architecture

```
FoundationModelsKit
├── Protocol layer
│   └── LanguageModelProviding   (sendMessage + streamMessage)
├── Backends
│   ├── OnDeviceLanguageModel    (Apple FoundationModels)
│   ├── AnthropicLanguageModel   (Anthropic Messages API)
│   └── MockLanguageModel        (test double)
├── Routing
│   ├── ModelRouter              (privacy-first dispatch)
│   ├── RetryingLanguageModel    (exponential backoff wrapper)
│   ├── DynamicProfile           (routing + context config)
│   └── RegionalAvailability     (per-region tier selection)
├── Conversation
│   └── ConversationStore        (transcript + compaction + persistence)
├── Evaluation
│   └── EvaluationSuite          (pluggable metrics, concurrent)
└── Facade
    └── SDKIntegration           (wires everything together)
```

**Design rule:** no concrete type imports another concrete type. All coupling goes through `LanguageModelProviding`.

---

## Requirements

| Platform | Minimum version |
|----------|-----------------|
| macOS | 15.0 |
| iOS | 18.0 |
| watchOS | 11.0 |
| tvOS | 18.0 |
| visionOS | 2.0 |

Swift 6 strict concurrency is enforced across the entire module.

---

## License

MIT. See [LICENSE](LICENSE).
