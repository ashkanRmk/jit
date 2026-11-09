#!/usr/bin/env bash
# Phase 6 benchmark run (design §4.2): generates the synthetic repositories, drives the release app through
# every scenario, runs the JitBench micro-benchmarks, and writes
#   benchmarks/results/<date>-<sha>.json  +  benchmarks/results/<date>-<sha>-summary.md
# then compares against scripts/benchmarks/baseline/reference.json (when present).
#
#   scripts/benchmarks/run-all.sh [--quick] [--no-idle] [--ci] [--no-compare]
#     --quick       3 runs per scenario, 20 s idle samples (smoke run; not for reported numbers)
#     --no-idle     skip the idle scenarios (≈ 6 min)
#   JIT_BENCH_APP=<Jit.app> measures that app instead of the DerivedData Release build (Phase 7 release check).
#     --ci          non-UI only: micro-benchmarks; compare with loose thresholds
# Conditions for reported numbers (ADR-0041): release build, reference Mac on AC power, Low Power Mode off,
# nothing heavy running. Results contain metrics only — no paths, refs or repository content.
source "$(dirname "$0")/../build/common.sh"
DIR="$REPO_ROOT/scripts/benchmarks"
QUICK=0; IDLE=1; CI_MODE=0; COMPARE=1
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --no-idle) IDLE=0 ;;
        --ci) CI_MODE=1; IDLE=0 ;;
        --no-compare) COMPARE=0 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    esac
done
export JIT_BENCH_DIR="${JIT_BENCH_DIR:-$HOME/Library/Caches/jit-bench/p6}"
RUNS=10; [[ $QUICK -eq 1 ]] && RUNS=3
export JIT_BENCH_RUNS="$RUNS"
[[ $QUICK -eq 1 ]] && export JIT_IDLE_SETTLE=10 JIT_IDLE_SAMPLES=20
mkdir -p "$REPO_ROOT/benchmarks/results" "$DIR/out"
STAMP="$(date +%Y%m%d-%H%M%S)-$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
LINES="$DIR/out/run-$STAMP.txt"; : > "$LINES"
OUT="$REPO_ROOT/benchmarks/results/$STAMP.json"
SUMMARY="$REPO_ROOT/benchmarks/results/$STAMP-summary.md"

"$DIR/gen-repos.sh"
info "JitBench micro"
build_jitbench
"$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)/JitBench" micro --iterations $((RUNS * 3)) \
    --out "$DIR/out/micro-$STAMP.json"

if [[ $CI_MODE -eq 0 ]]; then
    # JIT_BENCH_APP=<path to Jit.app> measures another build (e.g. the release installed from the DMG).
    [[ -x "${JIT_BENCH_APP:-${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Release/Jit.app}/Contents/MacOS/Jit" ]] \
        || "$REPO_ROOT/scripts/build/build-app.sh" release
    B="$JIT_BENCH_DIR"
    run() { info "$*"; "$@" 2>&1 | tee -a "$LINES" || echo "scenario=$1 error=script-failed" >> "$LINES"; }
    run "$DIR/scenarios/launch-warm.sh"
    run "$DIR/scenarios/launch-cold.sh"
    run "$DIR/scenarios/app-scenario.sh" open-repo "$B/branchy-10k"
    run "$DIR/scenarios/app-scenario.sh" graph-scroll "$B/huge-100k"
    run "$DIR/scenarios/app-scenario.sh" diff-switch "$B/many-files"
    run "$DIR/scenarios/app-scenario.sh" large-diff "$B/large-diff"
    run "$DIR/scenarios/app-scenario.sh" many-files "$B/many-files"
    run "$DIR/scenarios/app-scenario.sh" multi-tab "$B/linear-1k" "$B/branchy-10k" "$B/huge-100k" "$B/many-files" "$B/wide-tree"
    run "$DIR/scenarios/app-scenario.sh" open-close-loop "$B/branchy-10k"
    if [[ $IDLE -eq 1 ]]; then
        run "$DIR/scenarios/idle.sh" 0
        run "$DIR/scenarios/idle.sh" 1 "$B/branchy-10k"
        run "$DIR/scenarios/idle.sh" 5 "$B/linear-1k" "$B/branchy-10k" "$B/huge-100k" "$B/many-files" "$B/wide-tree"
    fi
fi
python3 "$DIR/results.py" collect "$OUT" "$SUMMARY" "$LINES" "$DIR/out/micro-$STAMP.json"
info "results: $OUT"
if [[ $COMPARE -eq 1 && -f "$DIR/baseline/reference.json" ]]; then
    if [[ $CI_MODE -eq 1 ]]; then
        python3 "$DIR/results.py" compare <(python3 -c "import json,sys; b=json.load(open('$DIR/baseline/reference.json')); b['scenarios']={'micro': b['scenarios'].get('micro', {})}; json.dump(b, sys.stdout)") "$OUT" --loose
    else
        python3 "$DIR/results.py" compare "$DIR/baseline/reference.json" "$OUT"
    fi
fi
