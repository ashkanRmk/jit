#!/usr/bin/env bash
# §20 step 8: submits the signed DMG to Apple's notary service with the notarytool keychain profile
# $JIT_NOTARY_PROFILE (stored once by the owner: `xcrun notarytool store-credentials jit-notary …`), waits,
# saves the JSON result and, on failure, the log. Skips when this exact DMG (SHA-256) was already accepted.
source "$(dirname "$0")/lib.sh"
step "07 notarize"
[[ -f "$DMG" ]] || die "run 06-create-dmg.sh first"
is_adhoc && die "ad-hoc builds cannot be notarized: set JIT_SIGN_IDENTITY (Developer ID Application) in scripts/release/release.local.env"
sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
RESULT="$OUT/notary-$sha.json"
if [[ -f "$RESULT" ]] && grep -q '"status" *: *"Accepted"' "$RESULT"; then
    echo "  already accepted: $(awk -F'"' '/"id"/ {print $4; exit}' "$RESULT")"; exit 0
fi
xcrun notarytool history --keychain-profile "$JIT_NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$JIT_NOTARY_PROFILE' not found. Store it yourself (never in this repo):
  xcrun notarytool store-credentials $JIT_NOTARY_PROFILE --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>"
xcrun notarytool submit "$DMG" --keychain-profile "$JIT_NOTARY_PROFILE" --wait --timeout 2h \
    --output-format json >"$RESULT" || true
id="$(awk -F'"' '/"id"/ {print $4; exit}' "$RESULT")"
status="$(awk -F'"' '/"status"/ {print $4; exit}' "$RESULT")"
echo "  submission $id: $status"
if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$JIT_NOTARY_PROFILE" "$OUT/notary-log-$id.json" >/dev/null 2>&1
    [[ -f "$OUT/notary-log-$id.json" ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [print("  ", i.get("path"), "—", i.get("message")) for i in (d.get("issues") or [])]' "$OUT/notary-log-$id.json"
    die "notarization $status; log: $OUT/notary-log-$id.json"
fi
