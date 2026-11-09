#!/usr/bin/env bash
# Per-process wakeups, energy impact and GPU time for a running Jit (needs sudo; read-only sampling).
#   scripts/benchmarks/powermetrics.sh <pid> [samples=20] [interval_ms=1000]
# Prints JSON: mean CPU ms/s, interrupt wakeups/s, package-idle wakeups/s, energy impact, GPU ms/s.
set -euo pipefail
PID="${1:?usage: powermetrics.sh <pid> [samples] [interval_ms]}"; N="${2:-20}"; I="${3:-1000}"
OUT="$(mktemp -t jit-pm)"; trap 'rm -f "$OUT"' EXIT
sudo -n /usr/bin/powermetrics --samplers tasks --show-process-energy --show-process-gpu -i "$I" -n "$N" > "$OUT" 2>/dev/null \
    || { echo '{"error": "powermetrics needs sudo"}'; exit 0; }
python3 - "$OUT" "$PID" "$N" <<'PY'
import json, sys
path, pid, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
# Row: Name ID CPU-ms/s User% Deadlines<2 Deadlines2-5 Wakeups-Intr Wakeups-PkgIdle GPU-ms/s EnergyImpact.
# A process absent from a sample did nothing in it (counted as zeros).
rows = []
for line in open(path):
    parts = line.split()
    if len(parts) >= 10 and parts[-9] == pid:
        rows.append([float(x) for x in parts[-8:]])
def mean(i): return round(sum(r[i] for r in rows) / n, 3)
print(json.dumps({"samples": n, "samples_with_activity": len(rows), "cpu_ms_per_s": mean(0),
                  "interrupt_wakeups_per_s": mean(4), "pkg_idle_wakeups_per_s": mean(5), "gpu_ms_per_s": mean(6),
                  "energy_impact": mean(7)}))
PY
