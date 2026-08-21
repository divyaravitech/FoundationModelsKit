# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0]

First public release.

### Core

- `LanguageModelProviding` — the single-method protocol every backend implements,
  with a default `streamMessage(request:)` so every conformer supports streaming
  whether or not its backend does natively.
- `ModelRequest` / `ModelResponse` / `TokenUsage` — `Sendable`, `Codable`, and
  `Equatable` value types. `TokenUsage.isEstimated` distinguishes reported counts
  from heuristic ones.
- `LanguageModelError` with `unavailable`, `contextWindowExceeded`, and
  `toolNotSupported(_:)`.

### Routing

- `ModelRouter` — dispatches on `PrivacySensitivity` **before** any size or
  complexity heuristic. `.high` never leaves the device; `.medium` never reaches
  a third party; `.low` uses the full on-device → PCC → third-party chain.
- `ModelRouter.resolvedTier(for:)` reports where a request would go without
  sending it, returning `nil` in exactly the cases where routing would throw.
- `ModelRouter` conforms to `LanguageModelProviding`, so it composes anywhere a
  backend is expected.
- `RetryingLanguageModel` and `RetryPolicy` — exponential backoff with
  `.default`, `.aggressive`, and `.none` presets.
- `DynamicProfile` / `DynamicProfileBuilder` with `.onDeviceOnly`, `.balanced`,
  and `.cloudFirst` presets.
- `RegionalAvailability` — per-region backend availability, with
  `currentRegion()` inferred from the device time zone.

### Backends

- `OnDeviceLanguageModel` — Apple Intelligence via the `FoundationModels`
  framework, with a static `isAvailable` check. Builds on older OS versions and
  throws `.unavailable` there, so one binary ships everywhere.
- `AnthropicLanguageModel` — Anthropic Messages API over `URLSession`, including
  SSE streaming. No external dependencies.
- `MockLanguageModel` — actor-isolated test double recording call count and last
  request, with an injectable response handler for simulating failures.

### Conversation

- `ConversationStore` — actor-isolated transcript with context-window
  compaction that summarises the oldest turns and preserves the five most
  recent verbatim.
- JSON persistence via `save(to:)` / `load(from:)`.
- Compaction prompts are built at `.high` sensitivity, so conversation history
  is summarised on-device even when the original turns were not.

### Evaluation

- `EvaluationSuite` — runs metrics concurrently via `TaskGroup` while preserving
  result order.
- `NonEmptyMetric`, `LengthMetric`, and `ContainsKeywordsMetric`, the latter two
  awarding partial credit rather than a binary pass.
- `EvaluationResult.averageScore` for ranking.

### Integration

- `SDKIntegration` — facade wiring router, store, evaluation, and regional
  availability behind one `sendMessage(_:)` call, with a bounded diagnostic log.

### Documentation and examples

- DocC catalog with Getting Started, Privacy Routing, and Custom Backends
  articles, hosted by Swift Package Index.
- `Examples/PrivacyChat` — SwiftUI app whose banner shows live which tier the
  current draft would route to.
- `Examples/ChatDemo` — CLI walkthrough of all six feature areas.

[Unreleased]: https://github.com/divyaravitech/FoundationModelsKit/compare/1.0.0...HEAD
[1.0.0]: https://github.com/divyaravitech/FoundationModelsKit/releases/tag/1.0.0
