#!/usr/bin/env bash
# Records an Instruments trace of the release app and extracts Jit's signpost intervals (headless).
#   trace.sh <template> <seconds> <out.trace> [-- app arguments]
# Env passed through: JIT_OPEN, JIT_BENCH_REPOS, JIT_BENCH_RUNS (state dir is always a fresh temp dir).
# Examples:
#   JIT_OPEN=~/Library/Caches/jit-bench/p6/huge-100k trace.sh 'Time Profiler' 10 /tmp/open.trace
#   trace.sh 'Animation Hitches' 15 /tmp/scroll.trace -- -JitBenchmarkScenario graph-scroll   (+ JIT_OPEN)
#   trace.sh Allocations 60 /tmp/loop.trace -- -JitBenchmarkScenario open-close-loop          (+ JIT_BENCH_REPOS)
# The app is started through /usr/bin/env: `xctrace --launch <app>` resolves the bundle identifier through
# LaunchServices and may start another registered build of Jit (e.g. a Debug UI-test build).
set -euo pipefail
TEMPLATE="${1:?usage: trace.sh <template> <seconds> <out.trace> [-- args]}"; SECONDS_LIMIT="${2:?}"; OUT="${3:?}"
shift 3; [[ "${1:-}" == "--" ]] && shift
BUNDLE="${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Release/Jit.app"
STATE="$(mktemp -d -t jit-trace-state)"; trap 'rm -rf "$STATE"' EXIT
ENV_ARGS=(--env "JIT_APP_SUPPORT=$STATE")
for name in JIT_OPEN JIT_BENCH_REPOS JIT_BENCH_RUNS JIT_BENCHMARK_GRAPH; do
    [[ -n "${!name:-}" ]] && ENV_ARGS+=(--env "$name=${!name}")
done
rm -rf "$OUT"
xcrun xctrace record --template "$TEMPLATE" --instrument os_signpost --time-limit "${SECONDS_LIMIT}s" --output "$OUT" \
    "${ENV_ARGS[@]}" --launch -- /usr/bin/env "$BUNDLE/Contents/MacOS/Jit" "$@" >/dev/null || true
# xctrace exits non-zero when the time limit kills the target; the trace is still complete.
[[ -d "$OUT" ]] || { echo "error: no trace written" >&2; exit 1; }
pkill -f "$BUNDLE/Contents/MacOS/Jit" 2>/dev/null || true
python3 "$(dirname "$0")/signposts.py" "$OUT"
