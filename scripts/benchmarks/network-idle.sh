#!/usr/bin/env bash
# Network idle check: open sockets (lsof) and bytes moved (nettop) by a process over a window.
#   scripts/benchmarks/network-idle.sh <pid> [seconds=60]
# Prints JSON {sockets, bytes_in, bytes_out}; the target is zero for all three.
set -uo pipefail
PID="${1:?usage: network-idle.sh <pid> [seconds]}"; WINDOW="${2:-60}"
sample() {
    nettop -p "$PID" -L 1 -x 2>/dev/null | python3 -c '
import csv, sys
rows = list(csv.reader(sys.stdin))
if not rows: print(0, 0); raise SystemExit
h = rows[0]; i, o = h.index("bytes_in"), h.index("bytes_out")
print(sum(int(r[i] or 0) for r in rows[1:] if len(r) > o), sum(int(r[o] or 0) for r in rows[1:] if len(r) > o))'
}
read -r IN0 OUT0 <<< "$(sample)"
sleep "$WINDOW"
read -r IN1 OUT1 <<< "$(sample)"
SOCKETS="$( (lsof -nP -a -p "$PID" -i 2>/dev/null || true) | tail -n +2 | wc -l | tr -d ' ')"
echo "{\"sockets\": $SOCKETS, \"bytes_in\": $((IN1 - IN0)), \"bytes_out\": $((OUT1 - OUT0)), \"window_s\": $WINDOW}"
