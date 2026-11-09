#!/usr/bin/env bash
# §20 step 9: staples the notarization ticket to the DMG (covers the app inside for offline first launch).
source "$(dirname "$0")/lib.sh"
step "08 staple"
[[ -f "$DMG" ]] || die "run 06-create-dmg.sh first"
is_adhoc && die "ad-hoc builds have no notarization ticket to staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
