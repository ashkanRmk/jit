#!/usr/bin/env bash
# Builds a deterministic history fixture with git fast-import (GitTestKit's SyntheticHistory):
# main + feature branches, a merge every 20 commits, 200 tags, origin/main trailing main.
# Same arguments → same HEAD object id, byte for byte.
#
#   scripts/benchmarks/make-history-fixture.sh <commits> <branches> <out>
#   scripts/benchmarks/make-history-fixture.sh --standard     # 1k / 10k / 100k under $JIT_FIXTURES
#
# Fixtures live outside the repository: default ~/Library/Caches/jit-bench/.
source "$(dirname "$0")/../build/common.sh"
FIXTURES="${JIT_FIXTURES:-$HOME/Library/Caches/jit-bench}"

usage() { echo "usage: $0 <commits> <branches> <out> | --standard"; exit 2; }
[[ $# -ge 1 ]] || usage

info "building JitBench (release)"
swift build -c release --package-path "$PACKAGE_DIR" --product JitBench >/dev/null
BENCH="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)/JitBench"

if [[ "$1" == "--standard" ]]; then
    mkdir -p "$FIXTURES"
    for n in 1000 10000 100000; do
        out="$FIXTURES/history-$n"
        if [[ -d "$out" ]]; then info "$out exists, skipping"; continue; fi
        "$BENCH" make-history "$n" 50 "$out"
    done
    exit 0
fi
[[ $# -eq 3 ]] || usage
"$BENCH" make-history "$1" "$2" "$3"
