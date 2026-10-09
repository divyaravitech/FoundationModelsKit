# FoundationModelsKit

Route prompts to on-device or cloud models based on how sensitive they are.

[![CI](https://github.com/divyaravitech/FoundationModelsKit/actions/workflows/ci.yml/badge.svg)](https://github.com/divyaravitech/FoundationModelsKit/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

![Routing the same message at three privacy levels](docs/privacy-routing.gif)

## Why

Once your app can call both Apple Intelligence and a cloud API, you have to decide per request which one to use. That decision usually ends up as an `if` somewhere in a view model, and the privacy part of it — *this must not leave the device* — is the part that's easiest to get wrong six months later.

This makes it a parameter instead:

```swift
let response = try await router.respond(
    to: ModelRequest(
        content: "Summarise my medical notes.",
        privacySensitivity: .high,
        taskComplexity: .simple
    )
)
```

`.high` runs on-device. Not "prefers" — there is no fallback path, no configuration flag, and no request size that sends it anywhere else. If the on-device model can't handle it, the call fails rather than escalating.

| Sensitivity | Where it runs |
|---|---|
| `.high` | On-device only |
| `.medium` | On-device, or PCC if you supply one. Never third-party |
| `.low` | On-device → PCC → third-party |

Within `.medium` and `.low`, short simple prompts stay on-device anyway — no reason to pay network latency for "what's 2+2".

## Install

```swift
dependencies: [
    .package(url: "https://github.com/divyaravitech/FoundationModelsKit.git", from: "1.0.0")
]
```

## Use

```swift
import FoundationModelsKit

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
    throw ConfigError.missingAPIKey
}

let router = ModelRouter(
    onDevice: OnDeviceLanguageModel(),
    thirdParty: AnthropicLanguageModel(config: AnthropicConfiguration(apiKey: apiKey))
)

let response = try await router.respond(
    to: ModelRequest(content: "Write a haiku about Swift.", privacySensitivity: .low)
)
```

Streaming works on every backend, including ones with no native streaming:

```swift
for try await chunk in router.streamResponse(to: request) {
    print(chunk, terminator: "")
}
```

Retries with backoff:

```swift
let robust = RetryingLanguageModel(wrapped: router, policy: .default)
```

Conversation history that compacts itself before it overflows the context window, and survives app restarts:

```swift
let store = ConversationStore()
await store.addEntry(ConversationEntry(role: "user", content: "Hello"))

if await store.shouldCompact(maxTokens: 4096) {
    try await store.compact(using: router, maxTokens: 4096)
}

try await store.save(to: sessionURL)
let invoiceTurns = await store.search("invoice")
```

Tools:

```swift
struct Weather: ModelTool {
    let name = "get_weather"
    let description = "Current weather for a city."
    let parameterSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")])
    ])

    func call(arguments: JSONValue) async throws -> String {
        guard let city = arguments["city"]?.stringValue else {
            throw ToolError.invalidArguments("city is required")
        }
        return "18°C and clear in \(city)"
    }
}

let model = AnthropicLanguageModel(config: config, tools: [Weather()])
```

The kit runs the tool loop and feeds results back until the model stops asking.

The same tool works on-device — its JSON Schema is converted to Apple's runtime
schema type, so you don't need a `@Generable` Swift type:

```swift
let onDevice = OnDeviceLanguageModel(tools: [Weather()])
```

Quality checks on responses:

```swift
let suite = EvaluationSuite(metrics: [
    NonEmptyMetric(),
    LengthMetric(min: 20, max: 2000),
    ContainsKeywordsMetric(keywords: ["summary"]),
])

let result = await suite.evaluate(response: response, responseID: "turn-1")
```

## Try it

A SwiftUI app where the banner updates as you move the privacy control. Send a long prompt at `.low` and watch it go to the cloud; switch to `.high` and watch it refuse.

```bash
git clone https://github.com/divyaravitech/FoundationModelsKit.git
cd FoundationModelsKit/Examples/PrivacyChat && swift run PrivacyChat
```

| `.high` | `.low` |
|---|---|
| ![On-device](docs/screenshot-high.png) | ![Private Cloud Compute](docs/screenshot-low.png) |

Or the terminal walkthrough, which also covers retries, compaction and evaluation:

```bash
cd Examples/ChatDemo && swift run ChatDemo
```

![CLI demo](docs/cli-demo.gif)

Neither needs an API key or Apple Intelligence hardware.

## Backends

**`OnDeviceLanguageModel`** — Apple Intelligence, via `FoundationModels`. Needs macOS 26 / iOS 26 and supported hardware. On anything older it throws `.unavailable`, so you can ship one binary and fall back at runtime:

```swift
guard OnDeviceLanguageModel.isAvailable else { /* use cloud */ }
```

Token counts from this backend are estimated from character length — the framework doesn't report real ones. `TokenUsage.isEstimated` tells you which you got. Don't bill against estimates.

**`AnthropicLanguageModel`** — Messages API, SSE streaming, tool calling.

**`OpenAILanguageModel`** — Chat Completions API, SSE streaming.

**`GeminiLanguageModel`** — `generateContent`, SSE streaming.

**`MockLanguageModel`** — records calls, returns what you tell it to. For tests and previews.

All three cloud backends are plain `URLSession`. No dependencies.

Writing your own backend is one method — see [CONTRIBUTING.md](CONTRIBUTING.md).

## A note on PCC

The router has a `.pcc` tier and it's fully tested, so you can plug in your own Private Cloud Compute backend. But the kit can't ship one. `PrivateCloudComputeLanguageModel` exists in Apple's framework binary and is absent from the public interface — it doesn't compile. Details and the symbol dump are in [#2](https://github.com/divyaravitech/FoundationModelsKit/issues/2).

So in practice this is on-device vs. cloud today, with the middle tier ready if Apple opens it up.

## How it fits together

```
LanguageModelProviding          respond + streamResponse
├── OnDeviceLanguageModel       Apple Intelligence
├── AnthropicLanguageModel      Messages API
├── OpenAILanguageModel         Chat Completions
├── MockLanguageModel           tests
├── ModelRouter                 picks one, privacy first
└── RetryingLanguageModel       backoff wrapper

ConversationStore               history, compaction, search, persistence
EvaluationSuite                 pluggable response checks
TokenEstimating                 context budgeting
SDKIntegration                  all of the above behind one call
```

`ModelRouter` and `RetryingLanguageModel` are themselves `LanguageModelProviding`, so they nest.

No concrete type imports another — everything goes through protocols, which is why adding a backend touches no existing file. Swift 6 strict concurrency, no `@unchecked Sendable`.

More in [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

Swift 6. macOS 15+, iOS 18+, watchOS 11+, tvOS 18+, visionOS 2+.

The on-device backend additionally needs macOS 26 / iOS 26 and Apple Intelligence hardware. Everything else runs on the base versions.

## Migrating from 1.x

Two methods were renamed to match Apple's `LanguageModelSession`:

| 1.x | 2.0 |
|---|---|
| `sendMessage(request:)` | `respond(to:)` |
| `streamMessage(request:)` | `streamResponse(to:)` |

Calling code keeps compiling — the old names forward to the new ones and Xcode
offers the rename. If you wrote your own backend, rename the method in your
conformance; that part is a hard break.

## Versioning

Semver. Minor and patch releases won't break source compatibility within a major version; breaking changes ship in a major release and are listed in the [changelog](CHANGELOG.md).

`.high` never leaving the device is treated as a correctness property, not a nicety. If you find a case where it does, please [report it privately](SECURITY.md) rather than opening an issue.

Zero dependencies is a policy, not an accident — PRs adding one to the core target will be declined.

## What's next

| | |
|---|---|
| Exact token counts beyond Anthropic | OpenAI and Gemini expose counting endpoints too |
| Tool calling in the streaming path | works for complete responses today |
| PCC | [blocked on Apple](https://github.com/divyaravitech/FoundationModelsKit/issues/2) |

[Contributions welcome](CONTRIBUTING.md) — several issues are scoped as good first ones.

## Docs

[API reference](https://swiftpackageindex.com/divyaravitech/FoundationModelsKit/documentation) · [Getting started](Sources/FoundationModelsKit/Documentation.docc/GettingStarted.md) · [Privacy routing](Sources/FoundationModelsKit/Documentation.docc/PrivacyRouting.md) · [Custom backends](Sources/FoundationModelsKit/Documentation.docc/CustomBackends.md)

## License

MIT.
