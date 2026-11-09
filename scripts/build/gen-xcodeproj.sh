#!/usr/bin/env bash
# Generates macos/Jit.xcodeproj from macos/project.yml (ADR-0003). The project is git-ignored.
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: scripts/build/gen-xcodeproj.sh"; exit 0
fi
require_xcodegen
info "Generating $PROJECT"
xcodegen generate --spec "$MACOS_DIR/project.yml" --project "$MACOS_DIR" --quiet
