#!/usr/bin/env bash
# JIT_APP_ARGS: extra app arguments (e.g. "-JitOpaqueChrome YES" for the glass-cost A/B).
# Runs one in-app scenario on the release build: `-JitBenchmarkScenario <name>` with JIT_BENCH_REPOS, a fresh
# state directory (never the user's), and prints the app's result lines. Launched through LaunchServices.
#   scenarios/app-scenario.sh <scenario> <repo> [repo...]
set -euo pipefail
SCENARIO="${1:?usage: app-scenario.sh <scenario> <repo>...}"; shift
BUNDLE="${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Release/Jit.app"
[[ -x "$BUNDLE/Contents/MacOS/Jit" ]] || { echo "error: build first: scripts/build/build-app.sh release" >&2; exit 1; }
REPOS="$(IFS=:; echo "$*")"
STATE="$(mktemp -d -t jit-scenario-state)"
RESULT="$(mktemp -t jit-scenario)"
trap 'rm -rf "$STATE" "$RESULT"' EXIT
EXTRA_ENV=()
[[ "$SCENARIO" == graph-scroll ]] && EXTRA_ENV=(--env "JIT_OPEN=$1")
open -n -W --env "JIT_APP_SUPPORT=$STATE" --env "JIT_BENCHMARK_OUTPUT=$RESULT" --env "JIT_BENCH_REPOS=$REPOS" \
    --env "JIT_BENCH_RUNS=${JIT_BENCH_RUNS:-10}" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    -a "$BUNDLE" --args -JitBenchmarkScenario "$SCENARIO" ${JIT_APP_ARGS:-}
cat "$RESULT"
