#!/usr/bin/env bash
# Exercise the native updater with a disposable app installation and a real Jit release executable.
source "$(dirname "$0")/../release/lib.sh"
require_xcode
source_app="${1:-$APP}"
[[ -d "$source_app" ]] || die "pass the path to a staged Release Jit.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
[[ "$version" == "$JIT_VERSION" ]] || die "test app version must match the current checkout"
if ! /usr/sbin/DevToolsSecurity -status | grep -q 'enabled'; then
    die "native acceptance requires Developer Tools authorization"
fi

"$REPO_ROOT/scripts/build/gen-xcodeproj.sh"
"$REPO_ROOT/scripts/build/build-app.sh" debug
acceptance="$(mktemp -d "${TMPDIR:-/tmp}/jit-signed-update-acceptance.XXXXXX")"
credentials="$(mktemp -d "${TMPDIR:-/tmp}/jit-signed-update-key.XXXXXX")"
trap 'rm -rf "$credentials"' EXIT
key="$credentials/fixture.pem"
(umask 077; "${JIT_UPDATE_OPENSSL:-openssl}" genpkey -algorithm Ed25519 -out "$key")
public_key="$("$RELEASE_DIR/update-signing.sh" public-key "$key")"
bundle_id="com.ashkanrmk.jit.signedupdate.qa${acceptance##*.}"
mkdir -p "$acceptance/installed" "$acceptance/image" "$acceptance/valid" "$acceptance/tampered"
installed="$acceptance/installed/Jit.app"
replacement="$acceptance/image/Jit.app"
ditto "$DERIVED_DATA/Build/Products/Debug/Jit.app" "$installed"
ditto "$source_app" "$replacement"
for app in "$installed" "$replacement"; do
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Jit Signed Update Acceptance' "$plist"
    /usr/libexec/PlistBuddy -c 'Delete :JitUpdatePublicKey' "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :JitUpdatePublicKey string $public_key" "$plist"
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.2' "$installed/Contents/Info.plist"
codesign --force --deep --sign - "$installed"
codesign --force --sign - --options runtime "$replacement"
codesign --verify --strict --deep "$replacement"

image="Jit-$version.dmg"
valid="$acceptance/valid/$image"
hdiutil create -quiet -srcfolder "$acceptance/image" -volname "Jit Signed Update Acceptance" -format UDZO "$valid"
"$RELEASE_DIR/update-signing.sh" sign "$version" "$valid" "$key"
"$RELEASE_DIR/update-signing.sh" verify "$version" "$valid" "$public_key"
cp "$valid" "$valid.manifest" "$valid.manifest.sig" "$acceptance/tampered/"
printf '\0' >> "$acceptance/tampered/$image"
# Also replace the old-format checksum. It must have no bearing on verification.
(cd "$acceptance/tampered"; shasum -a 256 "$image" > "$image.sha256")

python3 - "$version" "$acceptance" <<'PY'
import json
import sys
from pathlib import Path

version, root = sys.argv[1:]
image = f'Jit-{version}.dmg'
download = f'https://github.com/ashkanRmk/jit/releases/download/{version}'
for folder in ('valid', 'tampered'):
    names = [image, f'{image}.manifest', f'{image}.manifest.sig']
    if folder == 'tampered':
        names.append(f'{image}.sha256')
    release = {
        'tag_name': version,
        'name': f'Jit {version} acceptance',
        'prerelease': True,
        'assets': [{'name': name, 'browser_download_url': f'{download}/{name}'} for name in names],
    }
    (Path(root) / folder / 'releases.json').write_text(json.dumps([release]), encoding='utf-8')
PY

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed"
export TEST_RUNNER_JIT_SIGNED_UPDATE_ACCEPTANCE="$acceptance"
export TEST_RUNNER_JIT_SIGNED_UPDATE_BUNDLE="$bundle_id"
export TEST_RUNNER_JIT_SIGNED_UPDATE_VERSION="$version"
info "Signed update acceptance artifacts: $acceptance/results.xcresult"
xcodebuild -project "$PROJECT" -scheme JitNativeInputAcceptance -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS' -resultBundlePath "$acceptance/results.xcresult" \
    -only-testing:JitNativeInputUITests/SignedUpdateAcceptanceTests -quiet test
