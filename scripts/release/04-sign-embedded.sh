#!/usr/bin/env bash
# §20 step 5: signs nested code inside-out (ADR-0046) — every Mach-O except the main executable, deepest
# first: the bundled Git (Contents/Resources/git), jit-git-helper (Contents/Helpers), any frameworks.
# Hardened Runtime on all of it, secure timestamp for Developer ID, no entitlements, never --deep.
source "$(dirname "$0")/lib.sh"
step "04 sign embedded code ($(is_adhoc && echo ad-hoc || echo "$JIT_SIGN_IDENTITY"))"
[[ -d "$APP" ]] || die "run 01-build-app.sh first"
IDENTITY="$(sign_identity)"
TS=(--timestamp); is_adhoc && TS=(--timestamp=none)
main="$APP/Contents/MacOS/Jit"
count=0
while IFS= read -r f; do
    [[ "$f" == "$main" ]] && continue
    codesign --force "${TS[@]}" --options runtime --prefix "$JIT_BUNDLE_ID." --sign "$IDENTITY" "$f" 2>&1 \
        | grep -v "replacing existing signature" || true
    count=$((count + 1))
done < <(macho_files "$APP/Contents" | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-)
echo "  signed $count nested Mach-O files"
