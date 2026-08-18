# PrivacyChat

A SwiftUI chat app that shows, live, which inference tier each message routes to as you change its privacy level.

```bash
cd Examples/PrivacyChat
swift run PrivacyChat
```

No API key or Apple Intelligence hardware required — the demo uses labelled stand-in backends so each tier announces itself.

## What to try

1. Send a short message at **High** sensitivity → banner shows **On-device**.
2. Switch to **Low**, set complexity to **Complex**, and send a long message → banner escalates to **Private Cloud Compute**.
3. Switch back to **High** with that same long message → it *refuses* to leave the device.

Step 3 is the point of the library. A `.high` request stays local regardless of how large or complex it is, and no configuration overrides that.

## Using real backends

Replace `DemoBackend` in `PrivacyChatApp.swift`:

```swift
self.router = ModelRouter(
    onDevice: OnDeviceLanguageModel(),
    thirdParty: AnthropicLanguageModel(
        config: AnthropicConfiguration(
            apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!
        )
    )
)
```
