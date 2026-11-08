# Shared helpers for scripts/build/*.sh. Sourced, not executed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS_DIR="$REPO_ROOT/macos"
PACKAGE_DIR="$MACOS_DIR/Packages/JitKit"
PROJECT="$MACOS_DIR/Jit.xcodeproj"
# Outside the repository on purpose: when the checkout lives in a TCC-protected folder (~/Documents,
# ~/Desktop) the xctest runner cannot load test bundles from it and hangs "preparing to run tests".
DERIVED_DATA="${JIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit}"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_xcode() {
    local dev
    dev="$(xcode-select -p 2>/dev/null)" || die "xcode-select is not configured. Install Xcode 26+ and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    [[ "$dev" == *".app/Contents/Developer" ]] || die "xcode-select points at '$dev' (Command Line Tools?). Jit needs full Xcode 26+: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    local major
    major="$(xcodebuild -version | awk 'NR==1 {split($2, v, "."); print v[1]}')"
    [[ "$major" -ge 26 ]] || die "Xcode $major found; Jit needs Xcode 26 or newer."
}

require_xcodegen() {
    command -v xcodegen >/dev/null || die "XcodeGen is not installed. Install it with: brew install xcodegen"
}
