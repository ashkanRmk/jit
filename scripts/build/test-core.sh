#!/usr/bin/env bash
# Runs the JitKit package tests (GitCore, GitTestKit-backed integration, DesignSystem) with swift test.
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: scripts/build/test-core.sh [extra swift test arguments]"; exit 0
fi
info "swift test ($PACKAGE_DIR)"
swift test --package-path "$PACKAGE_DIR" "$@"
