# Contributing

Contributions are welcome — especially new backends and evaluation metrics, which are designed to be added without touching core code.

## Getting set up

```bash
git clone https://github.com/divyaravitech/FoundationModelsKit.git
cd FoundationModelsKit
swift build
swift test
```

Run the demo to see everything working end to end:

```bash
cd Examples/ChatDemo && swift run ChatDemo
```

## The one architectural rule

**No concrete type imports another concrete type.** All coupling goes through protocols — `LanguageModelProviding` for backends, `EvaluationMetric` for quality checks.

This is what lets tests run against in-process fakes, lets the router swap backends at runtime, and lets you add a backend without a single change to existing files. A PR that imports one concrete model type into another will be asked to route through a protocol instead.

## Adding a backend

Conform to `LanguageModelProviding`. That's one required method:

```swift
struct MyBackend: LanguageModelProviding, Sendable {
    func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        // …
    }
}
```

Override `streamMessage(request:)` if your backend streams natively — otherwise the default implementation yields the full response as one chunk.

Please:
- Map your errors onto `LanguageModelError` so `RetryingLanguageModel` can respond correctly. `.unavailable` is retried; other cases are not.
- Use `TokenUsage.estimated(promptChars:completionChars:)` if exact counts aren't available, so `isEstimated` is set correctly.
- Prefer `struct` over `actor` unless you hold mutable state.

See [CustomBackends.md](Sources/FoundationModelsKit/Documentation.docc/CustomBackends.md) for the full guide, including streaming, error mapping, and concurrency.

## Adding an evaluation metric

Conform to `EvaluationMetric`:

```swift
struct MyMetric: EvaluationMetric, Sendable {
    let name = "MyMetric"

    func evaluate(response: ModelResponse) async -> EvaluationScore {
        let passed = /* … */
        return EvaluationScore(
            metricName: name,
            score: passed ? 1.0 : 0.0,
            passed: passed,
            details: passed ? nil : "why it failed"
        )
    }
}
```

Give partial credit in `score` where it's meaningful — `ContainsKeywordsMetric` returns `found / total` rather than a binary result, which makes batch ranking useful. Keep `passed` as the hard gate.

## Testing

Every PR needs tests. Use `MockLanguageModel` — the suite runs fully offline and there are no network-dependent tests in this repo.

```swift
@Test func myFeatureWorks() async throws {
    let mock = MockLanguageModel { _ in
        ModelResponse(content: "x", stopReason: "end_turn",
                      usage: TokenUsage(inputTokens: 1, outputTokens: 1))
    }
    // …
}
```

Swift 6 strict concurrency is enforced. If you need a mutable counter inside a `@Sendable` closure, use an actor — see `AttemptCounter` in the test file.

## Style

Match the surrounding code. Notably:
- `// MARK: -` sections in every file
- Doc comments (`///`) on all public symbols, with a usage example on major types
- Comments explain *why*, not *what*

## Pull requests

- One logical change per PR
- `swift build && swift test` must pass
- Update the README if you change public API

## Good first issues

Issues tagged [`good first issue`](https://github.com/divyaravitech/FoundationModelsKit/labels/good%20first%20issue) are scoped to be completable without deep knowledge of the codebase. Current candidates:

- **OpenAI backend** — mirror `AnthropicLanguageModel`, different request shape
- **PCC backend** — the routing tier exists but has no implementation
- **`JSONValidityMetric`** — check that a response parses as valid JSON
- **`SemanticSimilarityMetric`** — compare against an expected answer
- **Token counting** — replace the 4-chars-per-token heuristic with a real tokenizer
- **`ConversationStore` search** — find turns matching a predicate

Comment on the issue before starting so work isn't duplicated.
