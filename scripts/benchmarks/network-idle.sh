#!/usr/bin/env bash
# Network idle check: open sockets (lsof) and bytes moved (nettop) by a process over a window.
#   scripts/benchmarks/network-idle.sh <pid> [seconds=60]
# Prints JSON {sockets, bytes_in, bytes_out}; the target is zero for all three.
set -euo pipefail
PID="${1:?usage: network-idle.sh <pid> [seconds]}"; SECONDS_WINDOW="${2:-60}"
sample() { nettop -p "$PID" -L 1 -x -J bytes_in,bytes_out 2>/dev/null | awk -F, 'NR>1 {i+=$2; o+=$3} END {print i+0, o+0}'; }
read -r IN0 OUT0 <<< "$(sample)"
sleep "$SECONDS_WINDOW"
read -r IN1 OUT1 <<< "$(sample)"
SOCKETS="$(lsof -nP -a -p "$PID" -i 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
echo "{\"sockets\": $SOCKETS, \"bytes_in\": $((IN1 - IN0)), \"bytes_out\": $((OUT1 - OUT0)), \"window_s\": $SECONDS_WINDOW}"
