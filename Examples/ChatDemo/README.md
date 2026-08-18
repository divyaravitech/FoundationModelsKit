# ChatDemo

A runnable demonstration of every FoundationModelsKit feature — no API key, no Apple Intelligence hardware required.

```bash
cd Examples/ChatDemo
swift run ChatDemo
```

## What it shows

1. **Privacy routing** — the same large, complex prompt sent at `.high`, `.medium`, and `.low` sensitivity, showing that `.high` stays on-device while the others escalate.
2. **On-device eligibility** — short, simple prompts stay local even at `.low` sensitivity.
3. **Streaming** — token-by-token output through `streamMessage`.
4. **Retry** — a backend that fails twice and succeeds on the third attempt.
5. **Compaction** — 12 conversation turns compacted down to 6.
6. **Evaluation** — three quality metrics scored against a response.

The demo uses labelled stand-in backends so each tier announces itself. Swap `LabelledModel` for `OnDeviceLanguageModel()` or `AnthropicLanguageModel(...)` to run it against real inference.
