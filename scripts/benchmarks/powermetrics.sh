#!/usr/bin/env bash
# Per-process wakeups, energy impact and GPU time for a running Jit (needs sudo; read-only sampling).
#   scripts/benchmarks/powermetrics.sh <pid> [samples=20] [interval_ms=1000]
# Also reports WindowServer's GPU ms/s and energy for the same window (glass is composited there).
# Prints JSON: mean CPU ms/s, interrupt wakeups/s, package-idle wakeups/s, energy impact, GPU ms/s.
set -euo pipefail
PID="${1:?usage: powermetrics.sh <pid> [samples] [interval_ms]}"; N="${2:-20}"; I="${3:-1000}"
OUT="$(mktemp -t jit-pm)"; trap 'rm -f "$OUT"' EXIT
sudo -n /usr/bin/powermetrics --samplers tasks --show-process-energy --show-process-gpu -i "$I" -n "$N" > "$OUT" 2>/dev/null \
    || { echo '{"error": "powermetrics needs sudo"}'; exit 0; }
WS_PID="$(pgrep -x WindowServer | head -1)"
python3 - "$OUT" "$PID" "$N" "$WS_PID" <<'PY'
import json, sys
path, pid, n, ws = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
# Row: Name ID CPU-ms/s User% Deadlines<2 Deadlines2-5 Wakeups-Intr Wakeups-PkgIdle GPU-ms/s EnergyImpact.
# A process absent from a sample did nothing in it (counted as zeros).
rows, ws_rows = [], []
for line in open(path):
    parts = line.split()
    if len(parts) >= 10 and parts[-9] == pid:
        rows.append([float(x) for x in parts[-8:]])
    elif len(parts) >= 10 and parts[-9] == ws:
        ws_rows.append([float(x) for x in parts[-8:]])
def mean(i, source=None):
    source = rows if source is None else source
    return round(sum(r[i] for r in source) / n, 3)
print(json.dumps({"samples": n, "samples_with_activity": len(rows), "cpu_ms_per_s": mean(0),
                  "interrupt_wakeups_per_s": mean(4), "pkg_idle_wakeups_per_s": mean(5), "gpu_ms_per_s": mean(6),
                  "energy_impact": mean(7), "windowserver_gpu_ms_per_s": mean(6, ws_rows),
                  "windowserver_energy_impact": mean(7, ws_rows)}))
PY
