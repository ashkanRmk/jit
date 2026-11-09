#!/usr/bin/env bash
# §20 step 6: signs Jit.app itself (after 04) and verifies the whole bundle: strict deep verification, the
# runtime flag on every Mach-O, and (Developer ID) a secure timestamp and one Team ID everywhere.
source "$(dirname "$0")/lib.sh"
step "05 sign app ($(is_adhoc && echo ad-hoc || echo "$JIT_SIGN_IDENTITY"))"
[[ -d "$APP" ]] || die "run 01-build-app.sh first"
IDENTITY="$(sign_identity)"
TS=(--timestamp); is_adhoc && TS=(--timestamp=none)
# No entitlements: Hardened Runtime defaults, App Sandbox off (ADR-0045).
codesign --force "${TS[@]}" --options runtime --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
status=0; teams=""
while IFS= read -r f; do
    info="$(codesign -dv --verbose=4 "$f" 2>&1)"
    grep -qE "flags=0x[0-9a-f]*\(.*runtime" <<<"$info" || { echo "  no hardened runtime: ${f#$APP/}"; status=1; }
    if ! is_adhoc; then
        grep -q "^Timestamp=" <<<"$info" || { echo "  no secure timestamp: ${f#$APP/}"; status=1; }
        teams+="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$info")"$'\n'
    fi
done < <(macho_files "$APP")
if ! is_adhoc; then
    distinct="$(echo "$teams" | sed '/^$/d' | sort -u)"
    [[ "$(echo "$distinct" | wc -l | tr -d ' ')" == 1 ]] || { echo "  Team IDs differ: $distinct"; status=1; }
    [[ -z "$JIT_TEAM_ID" || "$distinct" == "$JIT_TEAM_ID" ]] || { echo "  Team ID $distinct != $JIT_TEAM_ID"; status=1; }
fi
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "<key>"; then
    echo "  unexpected entitlements on Jit.app"; status=1
fi
[[ $status -eq 0 ]] || die "signature verification failed"
echo "  ok: signed, hardened runtime on every Mach-O, no entitlements$(is_adhoc || echo ", timestamped, Team ID $distinct")"
