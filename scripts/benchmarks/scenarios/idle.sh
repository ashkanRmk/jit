#!/usr/bin/env bash
# Idle after settling with 0, 1 or 5 repository tabs (restored session in a fresh state dir), app active.
#   scenarios/idle.sh <0|1|5> [repo...]   (JIT_IDLE_SETTLE / JIT_IDLE_SAMPLES as in idle.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
TABS="${1:?usage: idle.sh <tabs> [repo...]}"; shift || true
STATE="$(mktemp -d -t jit-idle-state)"; trap 'rm -rf "$STATE"' EXIT
python3 - "$STATE" "$TABS" "$@" <<'PY'
import json, sys, uuid
state, tabs, repos = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
records = [{"id": str(uuid.uuid4()).upper(), "kind": "repository", "path": repos[i % len(repos)] if i < len(repos) else repos[0],
            "titleCache": f"tab{i}", "sidebarCollapsed": False, "inspectorCollapsed": True, "ui": {}} for i in range(tabs)] if repos else []
seen, unique = set(), []
for r in records:
    if r["path"] not in seen: seen.add(r["path"]); unique.append(r)
session = {"version": 1, "tabs": unique, "activeTabID": unique[0]["id"] if unique else None}
json.dump(session, open(f"{state}/session.json", "w"))
PY
JIT_APP_SUPPORT="$STATE" JIT_ACTIVATE="${JIT_ACTIVATE:-1}" ./idle.sh "p6-${TABS}tabs" >/dev/null
python3 - "out/idle-p6-${TABS}tabs.json" "$TABS" <<'PY'
import json, re, sys
r = json.load(open(sys.argv[1])); t = sys.argv[2]
fp = r["physical_footprint"] or "0 MB"
value, unit = fp.split()
mb = float(value) * {"KB": 1/1024, "MB": 1, "GB": 1024}.get(unit, 1)
print(f"scenario=idle-{t}tabs metric=cpu_percent value={r['cpu_percent_mean']:.3f} max={r['cpu_percent_max']:.3f} unit=%")
print(f"scenario=idle-{t}tabs metric=idle_wakeups_per_s value={r['idle_wakeups_per_sample_mean']:.3f} unit=1/s")
print(f"scenario=idle-{t}tabs metric=footprint value={mb:.1f} unit=MB")
print(f"scenario=idle-{t}tabs metric=threads value={r['threads_max']} unit=count")
PY
