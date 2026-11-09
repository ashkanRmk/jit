# Shared helpers for scripts/release/*.sh (sourced). Every step is idempotent and writes only under
# build/release/<version>/. Secrets never pass through here: signing uses the keychain identity name and
# notarization a notarytool keychain profile.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../build" && pwd)/common.sh"
RELEASE_DIR="$REPO_ROOT/scripts/release"
source "$RELEASE_DIR/release.env"
[[ -f "$RELEASE_DIR/release.local.env" ]] && source "$RELEASE_DIR/release.local.env"
VERSION_XCCONFIG="$MACOS_DIR/App/Config/Version.xcconfig"

# Value of KEY in Version.xcconfig (`KEY = value`).
xcconfig_value() {
    awk -v key="$1" -F' = ' '$1 == key { sub(/^[^=]*= /, ""); print; exit }' "$VERSION_XCCONFIG"
}

JIT_VERSION="$(xcconfig_value MARKETING_VERSION)"
JIT_BUILD="$(xcconfig_value CURRENT_PROJECT_VERSION)"
JIT_BUNDLE_ID="$(xcconfig_value PRODUCT_BUNDLE_IDENTIFIER)"
[[ -n "$JIT_VERSION" && -n "$JIT_BUILD" && -n "$JIT_BUNDLE_ID" ]] || die "could not read $VERSION_XCCONFIG"
# --version on the command line must agree with Version.xcconfig (one source of truth).
if [[ -n "${JIT_EXPECT_VERSION:-}" && "$JIT_EXPECT_VERSION" != "$JIT_VERSION" ]]; then
    die "--version $JIT_EXPECT_VERSION does not match MARKETING_VERSION $JIT_VERSION in $VERSION_XCCONFIG"
fi

OUT="$REPO_ROOT/build/release/$JIT_VERSION"
APP="$OUT/stage/Jit.app"
DMG="$OUT/Jit-$JIT_VERSION.dmg"
mkdir -p "$OUT"

# Ad-hoc mode (no Developer ID): JIT_ADHOC=1, or no identity configured.
is_adhoc() { [[ "${JIT_ADHOC:-0}" == 1 || -z "$JIT_SIGN_IDENTITY" ]]; }
sign_identity() { if is_adhoc; then echo "-"; else echo "$JIT_SIGN_IDENTITY"; fi; }

# Mach-O files under a directory (regular files only; symlinks are not code).
macho_files() {
    find "$1" -type f -print0 | while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q "Mach-O"; then echo "$f"; fi
    done
}

step() { echo; echo "━━ $* ━━"; }
