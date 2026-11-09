#!/usr/bin/env bash
# §20 steps 1–3: one clean Release archive of Jit.app (app, local Swift packages, jit-git-helper) for
# $JIT_ARCHS, copied to build/release/<version>/stage/Jit.app; dSYMs kept privately in .../dSYMs.
source "$(dirname "$0")/lib.sh"
step "01 build app ($JIT_VERSION ($JIT_BUILD), $JIT_ARCHS)"
require_xcode
"$REPO_ROOT/scripts/build/gen-xcodeproj.sh"
ARCHIVE="$OUT/Jit.xcarchive"
DD="${JIT_RELEASE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Jit-Release}"
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme Jit -configuration Release -derivedDataPath "$DD" \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    ARCHS="$JIT_ARCHS" ONLY_ACTIVE_ARCH=NO \
    clean archive >"$OUT/xcodebuild.log" 2>&1 \
    || { grep -E "error:|\*\* ARCHIVE FAILED" "$OUT/xcodebuild.log" | head -30 >&2; die "archive failed; log: $OUT/xcodebuild.log"; }
[[ -d "$ARCHIVE/Products/Applications/Jit.app" ]] || die "archive did not produce Jit.app"
rm -rf "$OUT/stage" "$OUT/dSYMs"
mkdir -p "$OUT/stage"
ditto "$ARCHIVE/Products/Applications/Jit.app" "$APP"
[[ -d "$ARCHIVE/dSYMs" ]] && ditto "$ARCHIVE/dSYMs" "$OUT/dSYMs"

plist="$APP/Contents/Info.plist"
# The commit the release was built from, shown in About (signing happens later, in 04/05).
commit="$(git -C "$REPO_ROOT" rev-parse --short=10 HEAD)"
git -C "$REPO_ROOT" diff --quiet HEAD -- macos scripts || commit="$commit-dirty"
/usr/libexec/PlistBuddy -c "Delete :JitSourceCommit" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :JitSourceCommit string $commit" "$plist"
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
[[ "$short" == "$JIT_VERSION" ]] || die "CFBundleShortVersionString $short != $JIT_VERSION"
[[ "$build" == "$JIT_BUILD" ]] || die "CFBundleVersion $build != $JIT_BUILD"
[[ "$bundle_id" == "$JIT_BUNDLE_ID" ]] || die "CFBundleIdentifier $bundle_id != $JIT_BUNDLE_ID"
[[ -x "$APP/Contents/Helpers/jit-git-helper" ]] || die "jit-git-helper is not embedded at Contents/Helpers"
echo "Jit.app $short ($build) $bundle_id → $APP"
