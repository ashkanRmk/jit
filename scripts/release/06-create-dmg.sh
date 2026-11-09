#!/usr/bin/env bash
# §20 step 7: builds the styled, compressed, signed DMG (ADR-0047): Jit.app + Applications link, a 1×/2×
# background, a custom volume icon, Finder layout set by AppleScript (JIT_DMG_LAYOUT=0 skips it, e.g. on
# machines where Finder automation is not allowed), HFS+, then $JIT_DMG_FORMAT (ULFO) read-only.
source "$(dirname "$0")/lib.sh"
step "06 create DMG"
[[ -d "$APP" ]] || die "run 01–05 first"
codesign --verify --strict "$APP" 2>/dev/null || die "Jit.app is not signed (run 04 and 05 first)"
VOLNAME="Jit $JIT_VERSION"
WORK="$OUT/dmg-work"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
rm -rf "$WORK" "$DMG"
mkdir -p "$STAGE/.background"

ditto "$APP" "$STAGE/Jit.app"
ln -s /Applications "$STAGE/Applications"
swift "$RELEASE_DIR/assets/dmg-background.swift" "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

size_mb=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${size_mb}m" "$RW"
# Attach under /Volumes (Finder only scripts mounted volumes); a name collision gets Finder's " 1" suffix,
# so everything below uses the actual mount point.
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" 2>/dev/null | grep Apple_HFS)"
DEV="$(awk '{print $1}' <<<"$ATTACH")"
MNT="$(awk -F'\t' '{print $NF}' <<<"$ATTACH")"
[[ -n "$DEV" && -d "$MNT" ]] || die "could not attach $RW"
trap 'hdiutil detach -quiet "$DEV" 2>/dev/null || true' EXIT
if [[ "${JIT_DMG_LAYOUT:-1}" == 1 ]]; then
    LAYOUT_NAME="$(basename "$MNT")"
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$LAYOUT_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Jit.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    sync
    [[ -f "$MNT/.DS_Store" ]] || die "Finder did not write the layout (.DS_Store); allow Automation for Finder or set JIT_DMG_LAYOUT=0"
fi
# Custom volume icon (the app icon), set after the Finder pass (Finder removes an existing .VolumeIcon.icns
# while it writes the layout): .VolumeIcon.icns + kHasCustomIcon (0x0400) in the root folder's FinderInfo.
ICNS="$APP/Contents/Resources/AppIcon.icns"
[[ -f "$ICNS" ]] || die "no AppIcon.icns in Jit.app (is AppIcon.icon in the target?)"
cp "$ICNS" "$MNT/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"
sync
hdiutil detach -quiet "$DEV" || { sleep 2; hdiutil detach -force -quiet "$DEV"; }
trap - EXIT
hdiutil convert -quiet "$RW" -format "$JIT_DMG_FORMAT" -o "$DMG"
rm -rf "$WORK"

IDENTITY="$(sign_identity)"
TS=(--timestamp); is_adhoc && TS=(--timestamp=none)
codesign --force "${TS[@]}" --sign "$IDENTITY" "$DMG"
codesign --verify --strict "$DMG"
echo "  $DMG ($(du -h "$DMG" | cut -f1), $JIT_DMG_FORMAT, $(is_adhoc && echo ad-hoc || echo "$JIT_SIGN_IDENTITY"))"
