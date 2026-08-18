# Launch materials

Drafts for promoting FoundationModelsKit. Not part of the package — delete or keep private as you prefer.

---

## Show HN

**Title:**
```
Show HN: A privacy-routing layer for Apple's three tiers of on-device/cloud LLM inference
```

**Body:**
```
Apple's ecosystem now has three places a prompt can run: on-device via Apple
Intelligence, on Private Cloud Compute, or on a third-party API. Each is a
different privacy bargain, and every app ends up rewriting the same dispatch
logic — is this sensitive enough to stay local? is it too big for the on-device
model? what happens when PCC isn't reachable?

The part that bothered me is that the privacy rule ends up as an `if` statement
scattered across call sites, where it's easy to get wrong.

FoundationModelsKit makes it a type. You declare how sensitive a request is and
the router decides where it's allowed to run:

    ModelRequest(
        content: "Summarise my medical notes.",
        privacySensitivity: .high,    // never leaves the device
        taskComplexity: .simple
    )

.high stays on-device regardless of size or complexity. There's no config that
overrides it — the check happens before any other heuristic. .medium can reach
PCC but never a third party. .low uses the full fallback chain.

Everything is protocol-first: one method (`sendMessage`) to add a backend, and
no concrete type imports another, so backends are swappable at runtime and
tests run against in-process fakes.

Also handles the surrounding boilerplate: streaming with a default
implementation for backends that don't support it natively, exponential-backoff
retries, conversation compaction when you approach the context window, and
pluggable evaluation metrics that run concurrently.

Swift 6 strict concurrency throughout, no external dependencies, MIT.

There's a runnable demo that needs no API key:

    git clone https://github.com/divyaravitech/FoundationModelsKit.git
    cd FoundationModelsKit/Examples/PrivacyChat && swift run PrivacyChat

Happy to hear where the routing heuristic breaks down for other people's use
cases — it's deliberately simple right now (content size, tool use, declared
complexity) and I suspect it needs to become pluggable.

https://github.com/divyaravitech/FoundationModelsKit
```

**Timing:** Tuesday–Thursday, 9–11am ET. Be available to answer comments for the first 2–3 hours.

---

## r/swift and r/iOSProgramming

**Title:**
```
I built a privacy-routing layer for Apple Intelligence / PCC / third-party LLM calls
```

**Body:**
```
Every app that touches language models on Apple platforms ends up writing the
same dispatch logic — should this run on-device, on Private Cloud Compute, or on
a third-party API? And the privacy rule usually ends up as a scattered `if`
statement.

I made it a type instead:

    let response = try await router.sendMessage(
        request: ModelRequest(
            content: "Summarise my medical notes.",
            privacySensitivity: .high,   // never leaves the device
            taskComplexity: .simple
        )
    )

`.high` stays on-device no matter how large or complex the request is. The
privacy check runs before any other heuristic, so there's no configuration path
that leaks it.

Also does streaming (with a default impl so every backend supports it),
retries with backoff, conversation compaction, and pluggable eval metrics.
Swift 6 strict concurrency, zero dependencies, MIT.

There's a SwiftUI demo where you can watch the routing change live as you move
the privacy slider — no API key needed:

    cd Examples/PrivacyChat && swift run PrivacyChat

https://github.com/divyaravitech/FoundationModelsKit

Would genuinely like feedback on the routing heuristic. Right now it's content
size + tool use + declared complexity, which I think is too naive — considering
making it pluggable.
```

**Note:** r/swift dislikes anything that reads as marketing. Lead with the problem, ask a real question at the end, and reply to every comment.

---

## Swift Forums — Related Projects

Post in https://forums.swift.org/c/related-projects/. Same content as the Reddit
post but more technical; the audience there will care about:

- The protocol-first design rule (no concrete type imports another)
- Why `ModelRouter` conforms to `LanguageModelProviding` (composability)
- The `struct` vs `actor` guidance for backends
- Swift 6 strict concurrency with no `@unchecked Sendable`

---

## iOS Dev Weekly

Email Dave Verwer via https://iosdevweekly.com/submit — one paragraph, link,
and why it's interesting. He favours things that are novel rather than
another wrapper. The angle: *a policy layer for the three-tier inference
choice Apple created, where the privacy guarantee is enforced by the type
system rather than convention.*

---

## Recording a demo GIF

The single highest-value promotional asset. Install the tooling:

```bash
brew install asciinema agg
```

Record the CLI demo:

```bash
cd Examples/ChatDemo
asciinema rec demo.cast -c "swift run ChatDemo"
agg demo.cast demo.gif --theme monokai --font-size 15
```

Then add to the top of the README:

```markdown
![Demo](docs/demo.gif)
```

For the SwiftUI app, use QuickTime (File → New Screen Recording), then convert:

```bash
ffmpeg -i recording.mov -vf "fps=12,scale=800:-1:flags=lanczos" -loop 0 privacychat.gif
```

Keep it under ~8 seconds and under 5 MB. The money shot is switching the
sensitivity control from Low to High on a long message and watching the banner
refuse to escalate.

---

## Ordering

1. Tag `1.0.0` and push
2. Record both GIFs, add to README
3. Swift Package Index (already submitted — verify docs built)
4. Swift Forums post
5. r/swift + r/iOSProgramming
6. iOS Dev Weekly email
7. Show HN last — it benefits from the repo already having a few stars

Don't do all of these the same day. Space them over 1–2 weeks so each has time
to generate discussion.
