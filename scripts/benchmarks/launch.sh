#!/usr/bin/env bash
# Warm-launch benchmark for the release app (-JitBenchmarkLaunch). Two modes:
#   (default) content: launch through LaunchServices (`open -n`, as a user launch does); ends when the
#             first window's root view has appeared and one main-queue turn has passed. Works even when
#             the caller is not frontmost (the window is created but the app may not become active).
#   --key:    launch through LaunchServices (`open -n`) and end when the window becomes key. Only works
#             when the calling app (e.g. Terminal) is frontmost, because macOS will not activate an app
#             launched from a background process.
# Both start at the kernel's process start time. Reports median / p90 over N runs (default 20).
# usage: [JIT_APP_SUPPORT=<state dir>] [JIT_BENCH_LABEL=<name>] scripts/benchmarks/launch.sh [--key] [runs]
# Cold launch (approximate): reboot, or run `sudo purge`, then run with runs=1. Not automated.
set -euo pipefail
MODE=content; RUNS=20
for arg in "$@"; do
    case "$arg" in
        --key) MODE=key ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) RUNS="$arg" ;;
    esac
done
LABEL="${JIT_BENCH_LABEL:-$MODE}"  # output file suffix
BUNDLE="${JIT_BENCH_APP:-${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Release/Jit.app}"
[[ -d "$BUNDLE" ]] || { echo "error: build first: scripts/build/build-app.sh release" >&2; exit 1; }
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/out"; mkdir -p "$OUT_DIR"
RESULT="$(mktemp -t jit-launch)"
trap 'rm -f "$RESULT"' EXIT
# JIT_APP_SUPPORT=<dir>: launch with that state (e.g. 5 restored tabs) instead of an empty one.
STATE_ARGS=(--env "JIT_APP_SUPPORT=${JIT_APP_SUPPORT:-$(mktemp -d -t jit-launch-state)}")
run_once() {
    rm -f "$RESULT"
    if [[ "$MODE" == key ]]; then
        open -n -W "${STATE_ARGS[@]}" --env JIT_BENCHMARK_OUTPUT="$RESULT" -a "$BUNDLE" --args -JitBenchmarkLaunch -JitBenchmarkTrigger key
    else
        open -n -W "${STATE_ARGS[@]}" --env JIT_BENCHMARK_OUTPUT="$RESULT" -a "$BUNDLE" --args -JitBenchmarkLaunch
    fi
    [[ -s "$RESULT" ]] || { echo "error: no measurement written" >&2; exit 1; }
    cat "$RESULT"
}
run_once >/dev/null  # warm-up (not recorded)
: > "$OUT_DIR/launch-$LABEL-samples.txt"
for _ in $(seq 1 "$RUNS"); do run_once >> "$OUT_DIR/launch-$LABEL-samples.txt"; sleep 0.5; done
python3 - "$OUT_DIR/launch-$LABEL-samples.txt" "$OUT_DIR/launch-$LABEL.json" "$MODE" <<'PY'
import json, re, statistics, sys, platform, subprocess
lines = [l for l in open(sys.argv[1]) if l.strip()]
values = sorted(float(re.search(r"first_window_ms=([\d.]+)", l).group(1)) for l in lines)
triggers = sorted({re.search(r"trigger=(\w+)", l).group(1) for l in lines})
def pct(p): return values[min(len(values) - 1, round((len(values) - 1) * p))]
result = {"benchmark": f"warm-launch-{sys.argv[3]}", "triggers": triggers, "runs": len(values),
          "median_ms": statistics.median(values), "p90_ms": pct(0.9), "min_ms": values[0], "max_ms": values[-1],
          "machine": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
          "macos": platform.mac_ver()[0]}
json.dump(result, open(sys.argv[2], "w"), indent=2)
print(f"warm launch ({sys.argv[3]}, triggers {triggers}): median {result['median_ms']:.1f} ms, p90 {result['p90_ms']:.1f} ms (n={len(values)})")
PY
