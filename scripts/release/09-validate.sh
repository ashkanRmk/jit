#!/usr/bin/env bash
# §20 step 10: verifies the release artifact and writes build/release/<version>/validation.txt: SHA-256, DMG
# signature, stapled ticket, Gatekeeper assessment of the DMG and of the app inside it, strict deep code
# signature, hardened runtime, architectures and bundled Git. In ad-hoc mode the Gatekeeper and ticket checks
# are recorded as expected rejections, and the release is reported as NOT distributable.
source "$(dirname "$0")/lib.sh"
step "09 validate"
[[ -f "$DMG" ]] || die "run 06-create-dmg.sh first"
REPORT="$OUT/validation.txt"
failures=0
{
    echo "Jit $JIT_VERSION ($JIT_BUILD) release validation — $(date -u '+%Y-%m-%d %H:%M:%SZ')"
    echo "Artifact: $(basename "$DMG")"
    echo "SHA-256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
    echo "Size:     $(du -h "$DMG" | cut -f1)"
    echo "Mode:     $(is_adhoc && echo 'ad-hoc (NOT distributable: not Developer ID signed, not notarized)' || echo "Developer ID: $JIT_SIGN_IDENTITY")"
    echo
} >"$REPORT"
record() { # name, expected (pass|reject), command...
    local name="$1" expect="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)" && rc=0 || rc=$?
    local verdict
    if [[ $rc -eq 0 && "$expect" == pass ]] || [[ $rc -ne 0 && "$expect" == reject ]]; then verdict="ok"; else verdict="FAIL"; failures=$((failures + 1)); fi
    printf '[%s] %s (exit %d, expected %s)\n%s\n\n' "$verdict" "$name" "$rc" "$expect" "$(sed 's/^/    /' <<<"$out")" >>"$REPORT"
    echo "  $verdict  $name"
}
G=pass; is_adhoc && G=reject
record "DMG signature" pass codesign --verify --strict --verbose=2 "$DMG"
record "DMG stapled ticket" "$G" xcrun stapler validate "$DMG"
record "Gatekeeper: DMG (open)" "$G" spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

MNT="$(mktemp -d "${TMPDIR:-/tmp}/jit-validate.XXXXXX")"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
INNER="$MNT/Jit.app"
record "App inside DMG: strict deep signature" pass codesign --verify --strict --deep --verbose=2 "$INNER"
record "Gatekeeper: app inside DMG (execute)" "$G" spctl --assess --type execute --verbose=2 "$INNER"
record "Hardened runtime on every Mach-O" pass sh -c '
    find "$1" -type f -print0 | while IFS= read -r -d "" f; do
        file -b "$f" | grep -q Mach-O || continue
        codesign -dv --verbose=4 "$f" 2>&1 | grep -qE "flags=0x[0-9a-f]*\(.*runtime" || { echo "no runtime: $f"; exit 1; }
    done; echo "all Mach-O hardened"' _ "$INNER"
record "Architectures ($JIT_ARCHS)" pass sh -c '
    find "$1" -type f -print0 | while IFS= read -r -d "" f; do
        file -b "$f" | grep -q Mach-O || continue
        a="$(lipo -archs "$f")"; [ "$a" = "$2" ] || { echo "$a: $f"; exit 1; }
    done; echo "all Mach-O: $2"' _ "$INNER" "$JIT_ARCHS"
record "Bundled Git runs from inside the app" pass sh -c '"$1/Contents/Resources/git/bin/git" --version && "$1/Contents/Resources/git/bin/git" --exec-path' _ "$INNER"
record "Applications link" pass test -L "$MNT/Applications"
record "Volume icon and background" pass test -f "$MNT/.VolumeIcon.icns" -a -f "$MNT/.background/background.tiff"
hdiutil detach -quiet "$MNT"; trap - EXIT; rmdir "$MNT" 2>/dev/null || true

echo "Result: $([[ $failures -eq 0 ]] && echo PASS || echo "FAIL ($failures)")$(is_adhoc && echo ' — ad-hoc build, not for distribution')" >>"$REPORT"
echo "  report: $REPORT"
[[ $failures -eq 0 ]] || die "$failures validation check(s) failed"
