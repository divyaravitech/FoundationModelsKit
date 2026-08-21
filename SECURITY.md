# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅ |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through [GitHub Security Advisories](https://github.com/divyaravitech/FoundationModelsKit/security/advisories/new), or email divyaravi.tech@gmail.com with `[SECURITY]` in the subject.

Please include the affected version, a description of the issue, and steps to reproduce if you have them. You can expect an initial response within 7 days.

## Scope

This library routes prompts between inference backends. The security properties most worth scrutinising are:

**Privacy routing enforcement.** `ModelRouter` guarantees that a request marked `privacySensitivity: .high` is only ever sent to the on-device backend, and that `.medium` never reaches a third-party backend. Any code path that violates this — including through `RetryingLanguageModel`, `ConversationStore.compact`, or `SDKIntegration` — is a security bug, not a routing bug. Please report it here rather than as a normal issue.

**Credential handling.** `AnthropicConfiguration.apiKey` is held in memory and sent as an `x-api-key` header. The library never logs it: `SDKIntegration`'s diagnostic log records only prompt and response snippets. If you find a path that writes credentials to disk or into a log, that is in scope.

**Conversation persistence.** `ConversationStore.save(to:)` writes plaintext JSON with no encryption. This is documented, intentional, and the caller's responsibility to place appropriately — for example inside an encrypted container or a Data Protection–enabled directory. Reports that "the file is not encrypted" are not treated as vulnerabilities, but a path traversal or unintended write location would be.

## Out of scope

- The security of third-party model providers themselves
- Prompt injection against a model you have chosen to route to
- Vulnerabilities in Apple's `FoundationModels` framework (report those to Apple)
