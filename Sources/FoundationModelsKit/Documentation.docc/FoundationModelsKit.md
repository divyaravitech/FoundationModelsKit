# ``FoundationModelsKit``

Route language model requests across on-device, Private Cloud Compute, and third-party backends — with privacy as the first constraint, not an afterthought.

## Overview

Apple's ecosystem now offers three tiers of language model inference, each with a different privacy and capability profile. Choosing between them — and degrading gracefully when one is unavailable — is policy logic that every app ends up rewriting.

FoundationModelsKit puts that policy in one place. Declare how sensitive a request is; the router decides where it can legally run.

```swift
let router = ModelRouter(onDevice: OnDeviceLanguageModel())

let response = try await router.sendMessage(
    request: ModelRequest(
        content: "Summarise my medical notes.",
        privacySensitivity: .high,   // never leaves the device
        taskComplexity: .simple
    )
)
```

### Privacy is enforced, not suggested

``ModelRouter`` checks ``PrivacySensitivity`` before any other heuristic. A `.high` request stays on-device regardless of how large or complex it is — there is no configuration that overrides this.

| Sensitivity | Where it runs |
|-------------|---------------|
| ``PrivacySensitivity/high`` | On-device only |
| ``PrivacySensitivity/medium`` | On-device or PCC; never third-party |
| ``PrivacySensitivity/low`` | Full chain: on-device → PCC → third-party |

### Everything is a protocol

Every backend conforms to ``LanguageModelProviding``. Swapping Apple Intelligence for Anthropic — or for a fake in tests — is a one-line change, and no concrete type ever imports another concrete type.

## Topics

### Essentials

- ``LanguageModelProviding``
- ``ModelRequest``
- ``ModelResponse``
- ``TokenUsage``

### Routing

- ``ModelRouter``
- ``PrivacySensitivity``
- ``TaskComplexity``
- ``ModelTier``

### Backends

- ``OnDeviceLanguageModel``
- ``AnthropicLanguageModel``
- ``AnthropicConfiguration``
- ``MockLanguageModel``

### Reliability

- ``RetryingLanguageModel``
- ``RetryPolicy``
- ``LanguageModelError``

### Conversation Management

- ``ConversationStore``
- ``ConversationEntry``

### Evaluation

- ``EvaluationSuite``
- ``EvaluationMetric``
- ``EvaluationScore``
- ``EvaluationResult``
- ``NonEmptyMetric``
- ``LengthMetric``
- ``ContainsKeywordsMetric``

### Configuration

- ``DynamicProfile``
- ``DynamicProfileBuilder``
- ``RoutingStrategy``

### Regional Availability

- ``RegionalAvailability``
- ``Region``
- ``ModelAvailability``

### Integration

- ``SDKIntegration``
- ``FoundationModelsKitConfiguration``
