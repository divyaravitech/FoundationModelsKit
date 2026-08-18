# Getting Started

Wire up a backend, route your first request, and add streaming and retries.

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/divyaravitech/FoundationModelsKit.git", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies…**

## Your first request

Pick a backend, wrap it in a router, and send:

```swift
import FoundationModelsKit

let router = ModelRouter(onDevice: OnDeviceLanguageModel())

let response = try await router.sendMessage(
    request: ModelRequest(
        content: "Write a haiku about Swift concurrency.",
        privacySensitivity: .low,
        taskComplexity: .simple
    )
)

print(response.content)
```

## Adding a cloud backend

The router takes up to three backends. It only escalates to a cloud tier when the request's ``PrivacySensitivity`` permits it:

```swift
let router = ModelRouter(
    onDevice: OnDeviceLanguageModel(),
    thirdParty: AnthropicLanguageModel(
        config: AnthropicConfiguration(
            apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!
        )
    )
)
```

Now a `.low` sensitivity request that is too large for on-device inference automatically lands on Anthropic — and a `.high` request never does.

## Streaming

Every backend supports streaming through ``LanguageModelProviding/streamMessage(request:)``. Backends without native streaming fall back to yielding the full response as one chunk, so this call site always works:

```swift
for try await chunk in router.streamMessage(request: request) {
    print(chunk, terminator: "")
}
```

## Surviving transient failures

Wrap any backend in ``RetryingLanguageModel`` for exponential backoff:

```swift
let robust = RetryingLanguageModel(wrapped: router, policy: .default)
let response = try await robust.sendMessage(request: request)
```

``RetryPolicy/default`` retries three times on ``LanguageModelError/unavailable``. Use ``RetryPolicy/aggressive`` for unreliable networks, or ``RetryPolicy/none`` to fail fast.

## Managing a conversation

``ConversationStore`` tracks turn history and compacts it before you hit the context window:

```swift
let store = ConversationStore()
await store.addEntry(ConversationEntry(role: "user", content: "Hello"))

if await store.shouldCompact(maxTokens: 4096) {
    try await store.compact(using: router, maxTokens: 4096)
}

// Survive app restarts
try await store.save(to: sessionURL)
```

Compaction summarises the oldest turns into a single entry and keeps the five most recent verbatim, so immediate context is never lost.

## Testing

``MockLanguageModel`` is an actor that records calls and returns canned responses — no network, no flakiness:

```swift
let mock = MockLanguageModel { _ in
    ModelResponse(
        content: "Deterministic reply",
        stopReason: "end_turn",
        usage: TokenUsage(inputTokens: 5, outputTokens: 3)
    )
}

let router = ModelRouter(onDevice: mock)
// … exercise your code …
#expect(await mock.callCount == 1)
```

## Next steps

- <doc:PrivacyRouting> — how the router decides
- <doc:CustomBackends> — conform your own model
