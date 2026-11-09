#!/usr/bin/env bash
# Physical footprint (the number Activity Monitor shows) of a running process, in MB, plus RSS.
#   scripts/benchmarks/footprint.sh <pid>
set -euo pipefail
PID="${1:?usage: footprint.sh <pid>}"
FP="$(footprint "$PID" 2>/dev/null | sed -nE 's/.*[Ff]ootprint:[[:space:]]*([0-9.]+)[[:space:]]*([KMG]B).*/\1 \2/p' | head -1)"
RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"
python3 - "$FP" "$RSS_KB" <<'PY'
import json, sys
value, unit = (sys.argv[1].split() + ["0", "MB"])[:2]
mb = float(value) * {"KB": 1/1024, "MB": 1, "GB": 1024}.get(unit, 1)
print(json.dumps({"physical_footprint_mb": round(mb, 1), "rss_mb": round(int(sys.argv[2] or 0) / 1024, 1)}))
PY
