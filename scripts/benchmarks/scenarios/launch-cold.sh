#!/usr/bin/env bash
# Cold launch (approximation): `sudo purge` before each run, 5 runs. Needs passwordless sudo for purge
# (`sudo -n`); otherwise prints "not-measured" and exits 0 so run-all continues.
set -euo pipefail
cd "$(dirname "$0")/.."
RUNS="${JIT_COLD_RUNS:-5}"
if ! sudo -n /usr/sbin/purge 2>/dev/null; then
    echo "scenario=launch-cold error=not-measured reason=needs-sudo-purge"
    exit 0
fi
: > out/launch-cold-samples.txt
for _ in $(seq 1 "$RUNS"); do
    sudo -n /usr/sbin/purge; sleep 2
    JIT_BENCH_LABEL=cold-one ./launch.sh "${JIT_LAUNCH_MODE:---key}" 1 >/dev/null
    tail -1 out/launch-cold-one-samples.txt >> out/launch-cold-samples.txt
done
python3 - <<'PY'
import re, statistics
v = sorted(float(re.search(r"first_window_ms=([\d.]+)", l).group(1)) for l in open("out/launch-cold-samples.txt") if l.strip())
p90 = v[min(len(v) - 1, round((len(v) - 1) * 0.9))]
print(f"scenario=launch-cold metric=first_window median={statistics.median(v):.3f} p90={p90:.3f} max={v[-1]:.3f} n={len(v)} unit=ms")
PY
