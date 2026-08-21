#!/bin/bash
#
# Captures one screenshot of the PrivacyChat window per privacy level and
# rebuilds the animated GIF used by the top-level README.
#
# Run from the PrivacyChat directory:
#
#     bash scripts/capture-screenshots.sh
#
# Requirements:
#   - Screen Recording permission for your terminal
#     (System Settings -> Privacy & Security -> Screen Recording)
#   - Pillow, for the GIF step:  pip3 install Pillow
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DOCS="$REPO_ROOT/docs"
BIN=".build/arm64-apple-macosx/debug/PrivacyChat"

echo "Building..."
swift build

# The app must be launched and captured within the same shell invocation.
# A backgrounded `swift run` that outlives its parent shell loses its window
# server connection, so we run the built binary directly and capture inline.
for level in high medium low; do
    echo "Capturing $level..."

    PRIVACYCHAT_DEMO=1 PRIVACYCHAT_DEMO_SENSITIVITY="$level" "$BIN" >/dev/null 2>&1 &
    APP_PID=$!

    # Give SwiftUI time to lay out and draw the window.
    sleep 6

    WINDOW_ID="$(swift scripts/window-id.swift)"
    # -l captures a single window; -o drops the shadow so there is no margin.
    screencapture -x -o -l"$WINDOW_ID" "/tmp/shot-$level.png"

    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
done

mkdir -p "$DOCS"
cp /tmp/shot-high.png "$DOCS/screenshot-high.png"
cp /tmp/shot-low.png  "$DOCS/screenshot-low.png"

echo "Building GIF..."
python3 "$DOCS/make-gif.py" "$DOCS/privacy-routing.gif"

echo
echo "Done:"
ls -lh "$DOCS"
