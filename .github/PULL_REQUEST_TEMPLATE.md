## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `swift build && swift test` passes
- [ ] New public symbols have `///` doc comments
- [ ] No concrete type imports another concrete type (coupling goes through protocols)
- [ ] Tests added, using `MockLanguageModel` — no network calls in CI

## If this touches routing

- [ ] `.high` sensitivity still cannot reach any off-device backend
- [ ] `.medium` still cannot reach a third-party backend
- [ ] `resolvedTier(for:)` still returns `nil` in exactly the cases where `routeRequest(_:)` throws

## If this adds a backend

- [ ] Errors are mapped onto `LanguageModelError` (`.unavailable` is what gets retried)
- [ ] Token counts are exact, or use `TokenUsage.estimated(promptChars:completionChars:)`
- [ ] `streamMessage` yields deltas, not cumulative snapshots
