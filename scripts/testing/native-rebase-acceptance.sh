#!/usr/bin/env bash
# Native macOS events, isolated app identity/state and real disposable Git history.
source "$(dirname "$0")/../build/common.sh"
require_xcode
if ! /usr/sbin/DevToolsSecurity -status | grep -q 'enabled'; then
    die "Developer Tools authorization is disabled. Enable it with owner approval before running XCUITest; this script never changes system permissions."
fi
"$REPO_ROOT/scripts/build/build-app.sh" debug
acceptance_dir="$(mktemp -d "${TMPDIR:-/tmp}/jit-native-acceptance.XXXXXX")"
acceptance_app="$acceptance_dir/Jit Native Acceptance.app"
acceptance_bundle_id="com.ashkanrmk.jit.nativeacceptance.qa${acceptance_dir##*.}"
ditto "$DERIVED_DATA/Build/Products/Debug/Jit.app" "$acceptance_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $acceptance_bundle_id" "$acceptance_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Jit Native Acceptance' "$acceptance_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Jit Native Acceptance' "$acceptance_app/Contents/Info.plist"
codesign --force --deep --sign - "$acceptance_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$acceptance_app"
info "Native input acceptance; results and screenshot attachments: $acceptance_dir/results.xcresult"
export TEST_RUNNER_JIT_NATIVE_FIXTURE_GIT="$(xcrun --find git)"
export TEST_RUNNER_JIT_NATIVE_APP="$acceptance_app"
xcodebuild -project "$PROJECT" -scheme JitNativeInputAcceptance -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS' \
    -resultBundlePath "$acceptance_dir/results.xcresult" -quiet test "$@"
