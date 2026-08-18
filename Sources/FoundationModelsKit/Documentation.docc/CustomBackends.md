# Custom Backends

Conform your own model to ``LanguageModelProviding``.

## The minimum

One method. That's the whole contract:

```swift
import FoundationModelsKit

struct MyLanguageModel: LanguageModelProviding {
    func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        let text = try await myAPI.complete(request.content)
        return ModelResponse(
            content: text,
            stopReason: "end_turn",
            usage: TokenUsage(inputTokens: 0, outputTokens: 0)
        )
    }
}
```

``LanguageModelProviding/streamMessage(request:)`` has a default implementation that calls `sendMessage` and yields the result as a single chunk — so your type is immediately usable everywhere, including in ``ModelRouter`` and ``RetryingLanguageModel``.

## Adding native streaming

Override `streamMessage` when your backend supports incremental output:

```swift
func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                for try await token in myAPI.stream(request.content) {
                    continuation.yield(token)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

Yield **deltas**, not cumulative snapshots — callers concatenate what they receive.

## Reporting token usage

If your backend reports exact counts, pass them through:

```swift
usage: TokenUsage(
    inputTokens: apiResponse.usage.promptTokens,
    outputTokens: apiResponse.usage.completionTokens,
    cachedInputTokens: apiResponse.usage.cachedTokens
)
```

If it doesn't, use ``TokenUsage/estimated(promptChars:completionChars:)``. It applies the ~4-characters-per-token heuristic and sets ``TokenUsage/isEstimated`` so downstream code can tell the difference:

```swift
usage: .estimated(
    promptChars: request.content.count,
    completionChars: text.count
)
```

Never report estimates as exact — billing and quota logic depends on that distinction.

## Mapping errors

Translate your backend's failures into ``LanguageModelError`` so the router and retry layer can respond correctly:

```swift
catch let error as MyAPIError {
    switch error {
    case .rateLimited, .serverUnavailable:
        throw LanguageModelError.unavailable      // RetryingLanguageModel retries this
    case .promptTooLong:
        throw LanguageModelError.contextWindowExceeded
    case .unknownTool(let name):
        throw LanguageModelError.toolNotSupported(name)
    }
}
```

``RetryPolicy`` retries ``LanguageModelError/unavailable`` by default. Mapping a transient failure to any other case means it will not be retried.

## Concurrency

``LanguageModelProviding`` refines `Sendable`. Two valid shapes:

**`struct`** — when all state is immutable after `init` (most HTTP clients, since `URLSession` is already thread-safe):

```swift
struct MyLanguageModel: LanguageModelProviding, Sendable {
    private let config: MyConfig      // let, not var
}
```

**`actor`** — when you hold mutable state such as a session cache or request counter:

```swift
actor MyLanguageModel: LanguageModelProviding {
    private var cache: [String: ModelResponse] = [:]
}
```

Prefer `struct`. Actor isolation on a backend that has no mutable state adds hop overhead for nothing.

## Using it

Custom backends are indistinguishable from built-in ones:

```swift
let router = ModelRouter(
    onDevice: OnDeviceLanguageModel(),
    thirdParty: MyLanguageModel()
)

let robust = RetryingLanguageModel(wrapped: router, policy: .aggressive)
```
