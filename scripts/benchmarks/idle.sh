#!/usr/bin/env bash
# Idle benchmark for the release app: launch, settle 30 s, then sample 60 s with top(1) (CPU %,
# energy impact, threads, idle wakeups) and read the physical footprint with footprint(1).
# top's IDLEW column is a cumulative per-process counter; the report gives the increase during sampling.
# usage: [JIT_OPEN=/path/to/repo] scripts/benchmarks/idle.sh [label] [-- extra app arguments]
# Window state: the app usually stays inactive (launched from a background process) unless JIT_ACTIVATE=1, which
# brings it to the front (key window) with `open -a` before the settle period.
# GPU power needs root and is not sampled here; run separately:
#   sudo powermetrics --samplers gpu_power -i 1000 -n 60
set -euo pipefail
LABEL="${1:-no-repo}"; shift || true
[[ "$LABEL" == "-h" || "$LABEL" == "--help" ]] && { sed -n '2,9p' "$0"; exit 0; }
[[ "${1:-}" == "--" ]] && shift
SETTLE="${JIT_IDLE_SETTLE:-30}"; SAMPLES="${JIT_IDLE_SAMPLES:-60}"
BUNDLE="${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}/Build/Products/Release/Jit.app"
[[ -x "$BUNDLE/Contents/MacOS/Jit" ]] || { echo "error: build first: scripts/build/build-app.sh release" >&2; exit 1; }
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/out"; mkdir -p "$OUT_DIR"
# Launched through LaunchServices (as a user launch is); the new instance's pid is looked up afterwards.
BEFORE="$(pgrep -f "$BUNDLE/Contents/MacOS/Jit" || true)"
ENV_ARGS=(); [[ -n "${JIT_OPEN:-}" ]] && ENV_ARGS=(--env "JIT_OPEN=$JIT_OPEN")
open -n "${ENV_ARGS[@]}" -a "$BUNDLE" --args "$@"
PID=""
for _ in $(seq 1 50); do
    PID="$(pgrep -nf "$BUNDLE/Contents/MacOS/Jit" || true)"
    [[ -n "$PID" && " $BEFORE " != *" $PID "* ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "error: app did not start" >&2; exit 1; }
trap 'kill $PID 2>/dev/null || true' EXIT
if [[ "${JIT_ACTIVATE:-0}" == "1" ]]; then sleep 2; open -a "$BUNDLE"; fi
sleep "$SETTLE"
top -l $((SAMPLES + 1)) -s 1 -pid "$PID" -stats pid,cpu,idlew,power,th > "$OUT_DIR/idle-$LABEL-top.txt"
footprint "$PID" > "$OUT_DIR/idle-$LABEL-footprint.txt" 2>&1 || true
python3 - "$OUT_DIR/idle-$LABEL-top.txt" "$OUT_DIR/idle-$LABEL-footprint.txt" "$OUT_DIR/idle-$LABEL.json" "$LABEL" "$PID" <<'PY'
import json, re, sys
top, fp, out, label, pid = sys.argv[1:]
rows = [line.split() for line in open(top) if line.strip().startswith(pid + " ") or line.split()[:1] == [pid]]
rows = rows[1:]  # first top sample has no CPU delta
cpu = [float(r[1]) for r in rows]; wake = [int(float(r[2])) for r in rows]; power = [float(r[3]) for r in rows]
threads = [int(r[4].split("/")[0]) for r in rows]
footprint = None
for line in open(fp):
    m = re.search(r"phys_footprint:\s*([\d.]+)\s*(\w+)", line) or re.search(r"Footprint:\s*([\d.]+)\s*(\w+)", line)
    if m: footprint = f"{m.group(1)} {m.group(2)}"; break
result = {"label": label, "samples": len(rows), "cpu_percent_mean": sum(cpu)/len(cpu), "cpu_percent_max": max(cpu),
          "idle_wakeups_during_sampling": wake[-1] - wake[0], "idle_wakeups_total_since_launch": wake[-1], "energy_impact_mean": sum(power)/len(power),
          "threads_max": max(threads), "physical_footprint": footprint}
json.dump(result, open(out, "w"), indent=2)
print(json.dumps(result))
PY
