#!/usr/bin/env bash
# Run after the offline signer returns the two signed assets. Writes a verified upload directory.
source "$(dirname "$0")/lib.sh"
step "10 prepare publish assets"
require_update_public_key
[[ -f "$OUT/validation.txt" ]] || die "run 09-validate.sh first"
grep -q '^Result: PASS' "$OUT/validation.txt" || die "release validation did not pass"
grep -q '^\[ok\] App inside DMG pins the configured update key' "$OUT/validation.txt" \
    || die "release validation did not check the pinned update key"
grep -Fxq "Update public key: $JIT_UPDATE_PUBLIC_KEY" "$OUT/validation.txt" \
    || die "configured update key differs from the validated DMG"
digest="$(shasum -a 256 "$DMG" | awk '{print $1}')"
grep -Fxq "SHA-256:  $digest" "$OUT/validation.txt" || die "disk image changed since release validation"
"$RELEASE_DIR/update-signing.sh" verify "$JIT_VERSION" "$DMG" "$JIT_UPDATE_PUBLIC_KEY"

source "$REPO_ROOT/scripts/build/git-version.env"
git_source="$REPO_ROOT/build/git-src/git-$GIT_VERSION.tar.xz"
[[ -f "$git_source" ]] || die "bundled Git source is missing"
work="$(mktemp -d "$OUT/.publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$DMG" "$DMG.manifest" "$DMG.manifest.sig" "$git_source" "$work/"
COPYFILE_DISABLE=1 tar -czf "$work/jit-git-build-scripts-$JIT_VERSION.tar.gz" -C "$REPO_ROOT/scripts/build" \
    build-git.sh git-version.env common.sh
(
    cd "$work"
    shasum -a 256 ./* > SHA256SUMS
)
# Older clients look for a separate DMG.sha256 file. Leave it out so they offer the manual download.
rm -rf "$OUT/publish"
mv "$work" "$OUT/publish"
echo "Verified upload assets: $OUT/publish"
