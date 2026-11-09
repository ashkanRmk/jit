#!/usr/bin/env bash
# Builds the Phase 6 benchmark repositories (design §4.2) deterministically under $JIT_BENCH_DIR
# (default ~/Library/Caches/jit-bench/p6 — outside the repository; never committed):
#   linear-1k  branchy-10k  huge-100k  many-files  large-diff  wide-tree
# Idempotent: an existing repository is verified against its manifest (refs + status digest) and kept;
# a mismatch is reported (rebuild with --force). Same script → same digests on every machine with Git ≥ 2.39.
#
#   scripts/benchmarks/gen-repos.sh [--force] [name...]
source "$(dirname "$0")/../build/common.sh"
BENCH_DIR="${JIT_BENCH_DIR:-$HOME/Library/Caches/jit-bench/p6}"
FORCE=0; NAMES=()
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) NAMES+=("$arg") ;;
    esac
done
swift build -c release --package-path "$PACKAGE_DIR" --product JitBench >/dev/null
BENCH="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)/JitBench"
[[ ${#NAMES[@]} -gt 0 ]] || read -r -a NAMES <<< "$("$BENCH" make-bench-repo --list)"
mkdir -p "$BENCH_DIR"

digest() {
    (cd "$1" && GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git for-each-ref --format='%(objectname) %(refname)' \
        && GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git status --porcelain=v2 -z --untracked-files=all) | shasum -a 256 | cut -d' ' -f1
}

status=0
for name in "${NAMES[@]}"; do
    out="$BENCH_DIR/$name"
    manifest="$BENCH_DIR/$name.manifest"
    if [[ -d "$out" && $FORCE -eq 0 ]]; then
        if [[ -f "$manifest" && "$(digest "$out")" == "$(cat "$manifest")" ]]; then
            info "$name: present, digest matches"
            continue
        fi
        echo "warning: $name exists but its digest differs from $manifest (rebuild with --force)" >&2
        status=1
        continue
    fi
    rm -rf "$out"
    "$BENCH" make-bench-repo "$name" "$out"
    digest "$out" > "$manifest"
    info "$name: digest $(cat "$manifest")"
done
exit $status
