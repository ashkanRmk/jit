#!/usr/bin/env bash
# Package the signed app in a styled, compressed DMG. Finder reads the layout written to the volume.
source "$(dirname "$0")/lib.sh"
step "06 create DMG"
require_dmg_tools
[[ -d "$APP" ]] || die "run 01–05 first"
codesign --verify --strict "$APP" 2>/dev/null || die "Jit.app is not signed (run 04 and 05 first)"

WORK="$(mktemp -d "$OUT/.dmg-work.XXXXXX")"
STAGE="$WORK/stage"
MNT="$WORK/mount"
RW="$WORK/rw.dmg"
CANDIDATE="$WORK/${DMG##*/}"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        hdiutil detach -force -quiet "$MNT" || return
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$STAGE/.background" "$MNT"

ditto "$APP" "$STAGE/Jit.app"
ln -s /Applications "$STAGE/Applications"
swift "$RELEASE_DIR/assets/dmg-background.swift" "$RELEASE_DIR/assets/dmg-layout.json" \
    "$REPO_ROOT/docs/assets/logotype-dark.svg" "$WORK/background.png" "$WORK/background@2x.png"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff"

size_mb=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil create -quiet -volname "Jit $JIT_VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${size_mb}m" "$RW"
hdiutil attach -quiet -readwrite -noverify -nobrowse -noautoopen -mountpoint "$MNT" "$RW"
mounted=1
"$DMG_PYTHON" "$RELEASE_DIR/assets/dmg-layout.py" write "$MNT"
cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"
sync
hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -force -quiet "$MNT"; }
mounted=0
hdiutil convert -quiet "$RW" -format "$JIT_DMG_FORMAT" -o "$CANDIDATE"

TS=(--timestamp); is_adhoc && TS=(--timestamp=none)
codesign --force "${TS[@]}" --sign "$(sign_identity)" "$CANDIDATE"
codesign --verify --strict "$CANDIDATE"
mv -f "$CANDIDATE" "$DMG"
echo "  $DMG ($(du -h "$DMG" | cut -f1), $JIT_DMG_FORMAT, $(is_adhoc && echo ad-hoc || echo "$JIT_SIGN_IDENTITY"))"
