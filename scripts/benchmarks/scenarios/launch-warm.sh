#!/usr/bin/env bash
# Warm launch → first window (median/p90 over JIT_BENCH_RUNS, default 10, after a warm-up). Uses launch.sh;
# JIT_LAUNCH_MODE=--key (default; needs the caller frontmost) or "content".
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${JIT_LAUNCH_MODE:---key}"; [[ "$MODE" == content ]] && MODE=""
JIT_BENCH_LABEL=warm ./launch.sh $MODE "${JIT_BENCH_RUNS:-10}" >/dev/null
python3 - <<'PY'
import json
r = json.load(open("out/launch-warm.json"))
print(f"scenario=launch-warm metric=first_window median={r['median_ms']:.3f} p90={r['p90_ms']:.3f} "
      f"max={r['max_ms']:.3f} n={r['runs']} unit=ms triggers={','.join(r['triggers'])}")
PY
