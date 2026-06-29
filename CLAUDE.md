# FoundationModelsKit — Architecture

## Philosophy: Protocol-First Design

Every capability is expressed as a Swift protocol before any concrete implementation exists. This lets tests run against fast in-process fakes, lets the router swap backends at runtime, and lets third-party contributors add new backends without touching core kit code.

The one rule: **no concrete model type is imported by another concrete model type**. All coupling goes through protocols.

---

## Five Core Pieces (Phases 1–2, complete)

### 1. `LanguageModelProviding`
```
Sources/FoundationModelsKit/LanguageModelProviding.swift
```
The single method every backend must implement:
```swift
func sendMessage(request: ModelRequest) async throws -> ModelResponse
```
Supporting types live in the same file: `ModelRequest`, `ModelResponse`, `TokenUsage`, `ModelTier`, `PrivacySensitivity`, `TaskComplexity`, `LanguageModelError`.

### 2. `ModelRequest` / `ModelResponse`
Fully `Sendable` + `Codable`. Requests carry a `privacySensitivity` field and a `taskComplexity` hint so the router can make policy decisions without inspecting prompt content.

### 3. `ModelRouter` *(Phase 3 — coming next)*
Accepts a `ModelRequest`, applies privacy + complexity rules, and dispatches to the appropriate `LanguageModelProviding` conformer:
- `high` sensitivity → on-device only
- `medium` + `complex` → PCC
- `low` + `complex` → third-party allowed

### 4. `ConversationStore` *(Phase 4 — coming next)*
An actor that holds the turn history for a session. Responsible for context-window budgeting (truncating old turns when approaching the limit) and optional on-disk persistence via `Codable`.

### 5. Tests
`Tests/FoundationModelsKitTests/` — uses `MockLanguageModel` exclusively so tests run offline with no flakiness.

---

## Roadmap

| Phase | What |
|-------|------|
| 1 | Protocol + data types ✅ |
| 2 | `MockLanguageModel` test double ✅ |
| 3 | `ModelRouter` with privacy/complexity dispatch |
| 4 | `ConversationStore` — turn history + context budgeting |
| 5 | On-device backend (Apple Foundation Models / Core ML) |
| 6 | PCC backend |
| 7 | Third-party backend (Anthropic Claude, etc.) |
| 8 | Tool-calling pipeline |
| 9 | SwiftUI integration layer |

---

## How to Use the Kit

```swift
import FoundationModelsKit

// In production — swap in a real backend conforming to LanguageModelProviding:
// let model: any LanguageModelProviding = OnDeviceLanguageModel()

// In tests:
let model = MockLanguageModel()

let request = ModelRequest(
    content: "Summarise this email in one sentence.",
    privacySensitivity: .high,   // stays on-device
    taskComplexity: .simple
)

let response = try await model.sendMessage(request: request)
print(response.content)
// → "This is a mock response for testing."
```

---

## Swift 6 Concurrency Notes

- All types are `Sendable` — safe to pass across actor boundaries.
- `MockLanguageModel` is an `actor` — its `callCount` and `lastRequest` are automatically protected.
- The `responseHandler` closure is marked `@Sendable` so it cannot capture mutable state from the caller.
- No `@unchecked Sendable` anywhere — strict checking is enforced via `swiftLanguageModes: [.v6]` in `Package.swift`.
