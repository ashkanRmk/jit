#!/usr/bin/env bash
# Runs the app-level test bundle (JitAppTests) through xcodebuild.
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: scripts/build/test-app.sh"; exit 0
fi
require_xcode
[[ -d "$PROJECT" ]] || "$(dirname "$0")/gen-xcodeproj.sh"
info "xcodebuild test (JitAppTests)"
xcodebuild -project "$PROJECT" -scheme Jit -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64' \
    -quiet test
