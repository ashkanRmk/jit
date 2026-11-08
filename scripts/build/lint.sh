#!/usr/bin/env bash
# Formatting lint (swift format) and architecture lint (no UI imports in GitCore, no hardcoded
# styling outside DesignSystem). The same rules are also enforced by unit tests.
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: scripts/build/lint.sh"; exit 0
fi
status=0
info "swift format lint"
swift format lint --strict --recursive --configuration "$REPO_ROOT/.swift-format" \
    "$PACKAGE_DIR/Sources" "$PACKAGE_DIR/Tests" "$MACOS_DIR/App" "$MACOS_DIR/AppTests" || status=1

info "GitCore imports"
if grep -rnE '^\s*(@preconcurrency\s+)?(public\s+|internal\s+)?import\s+(AppKit|SwiftUI|Cocoa|UIKit)' "$PACKAGE_DIR/Sources/GitCore"; then
    echo "GitCore must import Foundation/Darwin only (ADR-0002)" >&2; status=1
fi

info "Hardcoded styling outside DesignSystem"
pattern='Color\(red:|Color\(\.sRGB|NSColor\((red|srgbRed|calibratedRed|deviceRed|white):|#colorLiteral|\.font\(\.system\(size:|NSFont\.systemFont\(ofSize:|NSVisualEffectView|\.glassEffect\(|NSGlassEffectView\(|CIFilter|\.blur\(radius:'
if grep -rnE "$pattern" "$PACKAGE_DIR/Sources/Features" "$MACOS_DIR/App"; then
    echo "Use DesignSystem tokens and glass helpers instead" >&2; status=1
fi
exit $status
