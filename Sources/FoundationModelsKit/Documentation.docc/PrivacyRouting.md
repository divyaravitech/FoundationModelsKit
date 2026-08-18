# Privacy Routing

How ``ModelRouter`` decides where a request is allowed to run.

## The core guarantee

``ModelRouter`` evaluates ``PrivacySensitivity`` **before** any size or complexity heuristic. This ordering is the point of the library: no configuration, profile, or fallback path can send a `.high` sensitivity request off the device.

## The rules

### `.high` — on-device only

```swift
ModelRequest(content: transcript, privacySensitivity: .high)
```

Routed to the on-device model unconditionally. If the content is too large or the task too complex for good results, the request still runs on-device — it does not silently escalate. If on-device inference is unavailable, the call throws rather than falling back.

Use for: health data, financial records, private messages, anything under regulatory constraint.

### `.medium` — on-device or PCC

```swift
ModelRequest(content: draft, privacySensitivity: .medium)
```

Small, simple, tool-free requests run on-device. Anything larger escalates to Private Cloud Compute — Apple-operated infrastructure with no third-party involvement. If PCC is not configured, the request falls back to on-device rather than leaking to an external API.

Use for: user-authored content, drafts, notes — data you'd accept Apple processing but not a third party.

### `.low` — full chain

```swift
ModelRequest(content: publicDoc, privacySensitivity: .low)
```

Tries on-device, then PCC, then third-party. Throws ``LanguageModelError/unavailable`` only when every configured backend is exhausted.

Use for: public documents, synthetic data, non-sensitive queries.

## On-device eligibility

Within the `.medium` and `.low` tiers, a request stays on-device when **all three** hold:

- Content is under 500 characters
- No tools are requested
- ``TaskComplexity`` is ``TaskComplexity/simple``

Otherwise it escalates as far as its sensitivity permits.

## Inspecting decisions

``ModelRouter/resolvedTier(for:)`` reports where a request *would* go without sending it — useful for telemetry, debugging, and showing users which tier is handling their data:

```swift
if let tier = await router.resolvedTier(for: request) {
    print("Will run on: \(tier.rawValue)")
} else {
    print("No eligible backend — this request would throw")
}
```

It returns `nil` in exactly the cases where ``ModelRouter/routeRequest(_:)`` would throw, so it never reports a false success.

## Compaction inherits the guarantee

When ``ConversationStore`` compacts history, it builds the summarisation prompt with `.high` sensitivity. Conversation history is treated as the most sensitive payload in the system, so summarisation runs on-device even when the original turns did not.
