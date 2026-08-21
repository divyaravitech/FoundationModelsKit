# Documentation assets

Screenshots and the animated GIF used by the top-level README.

## Regenerating

Everything is scripted:

```bash
cd Examples/PrivacyChat
bash scripts/capture-screenshots.sh
```

That captures one window screenshot per privacy level, copies two of them into
`docs/`, and rebuilds the GIF.

**Requirements**

- Screen Recording permission for your terminal
  (System Settings → Privacy & Security → Screen Recording)
- Pillow for the GIF step: `pip3 install Pillow`

## How it works

The demo app accepts two environment variables so screenshots are reproducible
rather than hand-staged:

| Variable | Effect |
|---|---|
| `PRIVACYCHAT_DEMO=1` | Preloads a conversation exercising the on-device and PCC tiers, and fills the draft with a long, complex prompt |
| `PRIVACYCHAT_DEMO_SENSITIVITY` | `high` (default), `medium`, or `low` — pins the privacy control |

Because the prompt and complexity are identical across all three captures, the
only thing that changes between frames is the privacy control — which is
exactly the point being illustrated.

`scripts/window-id.swift` prints the app's `CGWindowID` so `screencapture -l`
can grab the window alone, with `-o` suppressing the drop shadow.

> **Note:** the capture script launches the built binary directly rather than
> using `swift run`. A backgrounded `swift run` that outlives its parent shell
> loses its window server connection and never draws a window, so the launch
> and the capture have to happen in the same shell invocation.

## Files

| File | Purpose |
|---|---|
| `privacy-routing.gif` | 900px wide, 4 frames, ~170 KB. Top of the README. |
| `screenshot-high.png` | `.high` sensitivity — routed on-device. |
| `screenshot-low.png` | Same message at `.low` — escalated to PCC. |
| `make-gif.py` | Builds the GIF from the three captured frames. |

The GIF cycles high → medium → low → medium so the loop reads as a control
being moved back and forth rather than snapping between two states.
