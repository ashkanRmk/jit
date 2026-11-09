#!/usr/bin/env bash
# Glass-chrome cost (design §4.1): GPU ms/s and energy of the release app (powermetrics, sudo) while it
#   1. idles with a repository open, 2. scrolls the graph (graph-scroll scenario), 3. resizes the window in
#   steps (AppleScript bounds changes — programmatic, not a live drag),
# with Jit's glass chrome and with -JitOpaqueChrome. Prints scenario lines.
#   scenarios/glass-cost.sh <repo>
set -euo pipefail
REPO="${1:?usage: glass-cost.sh <repo>}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Release/Jit.app"
sudo -n true 2>/dev/null || { echo "scenario=glass-cost error=not-measured reason=needs-sudo-powermetrics"; exit 0; }
pm() { "$DIR/powermetrics.sh" "$1" "$2" 500; }
# "<WindowServer GPU ms/s> <Jit energy> <WindowServer energy>"
gpu() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("%.3f %.3f %.3f" % (d["windowserver_gpu_ms_per_s"], d["energy_impact"], d["windowserver_energy_impact"]))' "$1"; }
for mode in glass opaque; do
    ARGS=(); [[ $mode == opaque ]] && ARGS=(-JitOpaqueChrome YES)
    STATE="$(mktemp -d -t jit-glass)"
    # Idle + resize: a plain launch with the repository open.
    open -n --env "JIT_APP_SUPPORT=$STATE" --env "JIT_OPEN=$REPO" -a "$BUNDLE" --args ${ARGS[@]+"${ARGS[@]}"}
    sleep 6
    PID="$(pgrep -nf "$BUNDLE/Contents/MacOS/Jit")"
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
    sleep 4
    read -r G E W <<< "$(gpu "$(pm "$PID" 10)")"
    echo "scenario=glass-cost metric=idle_ws_gpu_ms_per_s.$mode value=$G unit=ms/s jit_energy=$E ws_energy=$W"
    ( for i in $(seq 1 12); do
        osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set size of window 1 to {$((1000 + (i % 4) * 120)), $((700 + (i % 3) * 60))}" >/dev/null 2>&1
        sleep 0.25
      done ) &
    read -r G E W <<< "$(gpu "$(pm "$PID" 6)")"
    wait
    echo "scenario=glass-cost metric=resize_ws_gpu_ms_per_s.$mode value=$G unit=ms/s jit_energy=$E ws_energy=$W"
    kill "$PID"; sleep 1; rm -rf "$STATE"
    # Scroll: the graph-scroll scenario (400 one-screen steps).
    STATE="$(mktemp -d -t jit-glass)"; RESULT="$(mktemp -t jit-glass)"
    open -n --env "JIT_APP_SUPPORT=$STATE" --env "JIT_OPEN=$REPO" --env "JIT_BENCHMARK_OUTPUT=$RESULT" -a "$BUNDLE" \
        --args -JitBenchmarkScenario graph-scroll ${ARGS[@]+"${ARGS[@]}"}
    sleep 3
    PID="$(pgrep -nf "$BUNDLE/Contents/MacOS/Jit")"
    read -r G E W <<< "$(gpu "$(pm "$PID" 8)")"
    echo "scenario=glass-cost metric=scroll_ws_gpu_ms_per_s.$mode value=$G unit=ms/s jit_energy=$E ws_energy=$W"
    while kill -0 "$PID" 2>/dev/null; do sleep 1; done
    grep -o "graph_scroll_step_ms median=[0-9.]* p95=[0-9.]* max=[0-9.]* n=[0-9]* over_16ms=[0-9]*" "$RESULT" \
        | sed "s/^/scenario=glass-cost mode=$mode /" || true
    rm -rf "$STATE" "$RESULT"
done
