#!/usr/bin/env bash
# Launches the debug Jit.app with the given appearance and arguments, captures its window, quits.
# usage: scripts/testing/screenshot.sh <light|dark> <output.png> [window-title] [-- app arguments…]
# Needs Screen Recording permission for the terminal running it. Debug builds accept -JitOpen <path>.
set -euo pipefail
[[ $# -ge 2 ]] || { sed -n '2,4p' "$0"; exit 2; }
APPEARANCE="$1"; OUTPUT="$2"; shift 2
TITLE=""
if [[ $# -gt 0 && "$1" != "--" ]]; then TITLE="$1"; shift; fi
[[ "${1:-}" == "--" ]] && shift
APP="${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Debug/Jit.app/Contents/MacOS/Jit"
[[ -x "$APP" ]] || { echo "error: build the app first (scripts/build/build-app.sh debug)" >&2; exit 1; }
STYLE=(); [[ "$APPEARANCE" == "dark" ]] && STYLE=(-AppleInterfaceStyle Dark) || STYLE=(-AppleInterfaceStyle Light)
"$APP" "${STYLE[@]}" "$@" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
DIR="$(cd "$(dirname "$0")" && pwd)"
FINDER="${TMPDIR:-/tmp}/jit-window-id"
[[ -x "$FINDER" && "$FINDER" -nt "$DIR/window-id.swift" ]] || swiftc -O -o "$FINDER" "$DIR/window-id.swift"
for _ in $(seq 1 40); do
    if WID=$("$FINDER" "$PID" $TITLE 2>/dev/null); then break; fi
    sleep 0.25
done
[[ -n "${WID:-}" ]] || { echo "error: no window found" >&2; exit 1; }
sleep "${JIT_SCREENSHOT_SETTLE:-1.5}"
screencapture -x -o -l "$WID" "$OUTPUT"
echo "$OUTPUT"
