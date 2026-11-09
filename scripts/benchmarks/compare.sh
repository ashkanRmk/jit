#!/usr/bin/env bash
# Regression check: scripts/benchmarks/compare.sh [baseline.json] <candidate.json> [--loose]
# Default baseline: scripts/benchmarks/baseline/reference.json. Exit 1 on a regression or a missing metric.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -ge 2 && "$2" != --loose ]]; then BASE="$1"; shift; else BASE="$DIR/baseline/reference.json"; fi
exec python3 "$DIR/results.py" compare "$BASE" "$@"
