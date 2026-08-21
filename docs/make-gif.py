#!/usr/bin/env python3
"""Build the PrivacyChat demo GIF from the three captured frames.

Cycles High -> Medium -> Low -> Medium so the loop reads as a control
being dragged back and forth rather than snapping.
"""
from PIL import Image
import sys

SRC = ["/tmp/shot-high.png", "/tmp/shot-medium.png", "/tmp/shot-low.png"]
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/privacychat.gif"
WIDTH = 900          # keeps the file small while staying legible

frames = []
for path in SRC:
    im = Image.open(path).convert("RGB")
    ratio = WIDTH / im.width
    frames.append(im.resize((WIDTH, int(im.height * ratio)), Image.LANCZOS))

high, medium, low = frames
sequence = [high, medium, low, medium]
durations = [1600, 900, 1600, 900]

# Quantize with a shared adaptive palette so colours stay stable across frames.
quantized = [f.quantize(colors=128, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG)
             for f in sequence]

quantized[0].save(
    OUT,
    save_all=True,
    append_images=quantized[1:],
    duration=durations,
    loop=0,
    optimize=True,
    disposal=2,
)
print(f"wrote {OUT}")
