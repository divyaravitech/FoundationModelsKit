# FoundationModelsKit — Architecture

## Philosophy: Protocol-First Design

Every capability is expressed as a Swift protocol before any concrete implementation exists. This lets tests run against fast in-process fakes, lets the router swap backends at runtime, and lets contributors add backends without touching core code.

**The one rule:** no concrete model type is imported by another concrete model type. All coupling goes through protocols.

---

## Shipped surface

Everything below exists today in `Sources/FoundationModelsKit/`.

### Protocol layer — `LanguageModelProviding.swift`
```swift
func sendMessage(request: ModelRequest) async throws -> ModelResponse
func streamMessage(request: ModelRequest) -> AsyncThrowingStream<String, Error>
```
`streamMessage` has a default implementation that yields the full response as one chunk, so every backend supports streaming at the call site. Supporting types live in the same file: `ModelRequest`, `ModelResponse`, `TokenUsage`, `ModelTier`, `PrivacySensitivity`, `TaskComplexity`, `LanguageModelError`.

### Routing — `ModelRouter.swift`
Privacy is evaluated **before** any size or complexity heuristic:

| `privacySensitivity` | Routing |
|---|---|
| `.high` | On-device only — never escalates, whatever the size |
| `.medium` | On-device or PCC; falls back to on-device rather than a third party |
| `.low` | on-device → PCC → third-party, then throws `.unavailable` |

Within `.medium`/`.low`, a request stays on-device when it is under 500 characters, requests no tools, and is `.simple`. `resolvedTier(for:)` reports the decision without sending, and returns `nil` exactly when `routeRequest` would throw.

`ModelRouter` itself conforms to `LanguageModelProviding`, so it composes anywhere a backend is expected.

### Backends
- `OnDeviceLanguageModel` — Apple `FoundationModels`; requires macOS 26 / iOS 26. Compiles everywhere, throws `.unavailable` where unsupported. Token counts are **estimated** (`TokenUsage.isEstimated == true`).
- `AnthropicLanguageModel` — Messages API over `URLSession`, SSE streaming, no dependencies.
- `MockLanguageModel` — actor test double; records `callCount` and `lastRequest`.
- `RetryingLanguageModel` — wraps any backend with exponential backoff.

### Conversation — `ConversationStore.swift`
Actor holding turn history, with context-window compaction (summarise the oldest turns, keep the five most recent verbatim) and `save(to:)` / `load(from:)` persistence.

### Evaluation — `EvaluationSuite.swift`
Pluggable `EvaluationMetric` conformers, run concurrently. Built-ins: `NonEmptyMetric`, `LengthMetric`, `ContainsKeywordsMetric`.

### Configuration & region
`DynamicProfileBuilder` / `DynamicProfile` (pre-built: `.onDeviceOnly`, `.balanced`, `.cloudFirst`), and `RegionalAvailability` for per-region tier selection.

### Facade — `SDKIntegration.swift`
Wires routing, compaction, evaluation, transcript, and diagnostics behind one `sendMessage`. The injected `EvaluationSuite` decides which metrics run; `config.evaluationMetrics` only decides *whether* they run.

---

## Invariants — do not regress these

1. **`.high` never leaves the device.** This is a correctness property, not a convenience. Changing it is a security bug.
2. **Every `AsyncThrowingStream` sets `onTermination` and cancels its task.** A consumer that breaks early must not leave a request running and billing.
3. **A stream that has already yielded is never retried.** Replaying it duplicates partial output.
4. **`Codable` types decode data missing newer fields.** Synthesized `init(from:)` ignores property defaults and throws `keyNotFound`; hand-write `init(from:)` with `decodeIfPresent` when adding a field.
5. **No `@unchecked Sendable`.** Swift 6 strict concurrency, enforced via `swiftLanguageModes: [.v6]`.
6. **Zero runtime dependencies** in the core target.
7. **Anthropic model IDs are never date-suffixed** — `claude-opus-5-5`, not `claude-opus-5-5-20260401`.

## Testing

`Tests/FoundationModelsKitTests/` runs fully offline against `MockLanguageModel` — no network, no flakiness. Every PR needs tests. For mutable state inside a `@Sendable` closure, use an actor.

## Roadmap

| Status | Item |
|---|---|
| ✅ | Protocol layer, routing, conversation, evaluation, profiles, region, facade |
| ✅ | Streaming, retries, persistence, on-device + Anthropic backends |
| ⛔️ | PCC backend — blocked; `PrivateCloudComputeLanguageModel` is in Apple's binary but absent from the public interface (issue #2) |
| 📋 | Tool calling — `ModelRequest.tools` is a name hint only (issue #7) |
| 📋 | OpenAI/Gemini backends (#1), real tokenizer (#5), `ConversationStore` search (#6) |
