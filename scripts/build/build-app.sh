#!/usr/bin/env bash
# Builds Jit.app. Output: build/DerivedData/Build/Products/<Debug|Release>/Jit.app
source "$(dirname "$0")/common.sh"
usage() { echo "usage: scripts/build/build-app.sh [debug|release]"; }
case "${1:-debug}" in
    debug) CONFIG=Debug ;;
    release) CONFIG=Release ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown configuration '$1'" ;;
esac
require_xcode
[[ -d "$PROJECT" ]] || "$(dirname "$0")/gen-xcodeproj.sh"
info "Building Jit ($CONFIG)"
xcodebuild -project "$PROJECT" -scheme Jit -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64' \
    -quiet build
echo "Built $DERIVED_DATA/Build/Products/$CONFIG/Jit.app"
