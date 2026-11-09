#!/usr/bin/env bash
# Runs the JitKit package tests (GitCore, GitTestKit-backed integration, DesignSystem) with swift test.
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: scripts/build/test-core.sh [extra swift test arguments]"; exit 0
fi
info "swift test ($PACKAGE_DIR)"
# A full run skips only the load-sensitive wall-clock assertions (PerfBudget.enforcesTiming).
if [[ $# -eq 0 ]]; then export JIT_FULL_SUITE=1; fi
# JIT_TEST_SERIAL=1 (CI): run tests one at a time. A shared runner has few cores, and hundreds of Git-spawning
# tests in parallel there push individual tests past their (already scaled) wall-clock limits.
EXTRA=()
[[ "${JIT_TEST_SERIAL:-0}" == 1 ]] && EXTRA+=(--no-parallel)
swift test --package-path "$PACKAGE_DIR" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
