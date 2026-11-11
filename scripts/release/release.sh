#!/usr/bin/env bash
# Runs the release steps 01–09 (§20) and prints a summary.
#
#   scripts/release/release.sh [--version X.Y.Z] [--adhoc] [--skip-notarize] [--from-step N]
#
# --version     must equal MARKETING_VERSION in macos/App/Config/Version.xcconfig (the single source).
# --adhoc       sign with "-" (no Developer ID); implies --skip-notarize. Default when no identity is set.
# --skip-notarize  stop after the DMG (steps 07–08 skipped); 09 then validates structure only.
# --from-step N resume at step N (01–09); earlier outputs in build/release/<version>/ are reused.
set -euo pipefail
FROM=1; SKIP_NOTARIZE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) export JIT_EXPECT_VERSION="$2"; shift 2 ;;
        --adhoc) export JIT_ADHOC=1; SKIP_NOTARIZE=1; shift ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --from-step) FROM=$((10#$2)); shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
if is_adhoc; then SKIP_NOTARIZE=1; export JIT_ADHOC=1; fi
start=$SECONDS
for n in 01 02 03 04 05 06 07 08 09; do
    (( 10#$n < FROM )) && continue
    if [[ $SKIP_NOTARIZE -eq 1 && ( $n == 07 || $n == 08 ) ]]; then echo; echo "━━ $n skipped (no notarization) ━━"; continue; fi
    "$DIR/$n"-*.sh
done
sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
notary="$(ls "$OUT"/notary-"$sha".json 2>/dev/null | head -1 || true)"
echo
echo "━━ Summary ━━"
echo "  Version     $JIT_VERSION ($JIT_BUILD), $JIT_BUNDLE_ID, $JIT_ARCHS"
echo "  Artifact    $DMG"
echo "  SHA-256     $sha"
echo "  Signing     $(is_adhoc && echo 'ad-hoc (not distributable)' || echo "$JIT_SIGN_IDENTITY")"
if [[ -n "$notary" ]]; then
    echo "  Notary      $(awk -F'"' '/"id"/ {print $4; exit}' "$notary") $(awk -F'"' '/"status"/ {print $4; exit}' "$notary")"
    echo "  Stapled     $(xcrun stapler validate "$DMG" >/dev/null 2>&1 && echo yes || echo no)"
else
    echo "  Notary      not submitted"
fi
echo "  Validation  $OUT/validation.txt ($(tail -1 "$OUT/validation.txt"))"
echo "  Took        $((SECONDS - start)) s"
echo
echo "Next: tag $JIT_VERSION, push, create the GitHub Release (DMG + .sha256), then update the website —"
echo "      mandatory after every release: scripts/site/publish.sh --version $JIT_VERSION"
