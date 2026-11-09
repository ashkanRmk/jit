#!/usr/bin/env bash
# Asserts every Mach-O in Jit.app has exactly the release architectures ($JIT_ARCHS, ADR-0049), that the
# helper and Git are present, and that no development-only code (TestRig, JitBench, GitTestKit, test bundles,
# Swift modules) is embedded.
source "$(dirname "$0")/lib.sh"
step "03 verify architectures and contents"
[[ -d "$APP" ]] || die "run 01-build-app.sh first"
expected="$(echo "$JIT_ARCHS" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
status=0; count=0
while IFS= read -r f; do
    count=$((count + 1))
    archs="$(lipo -archs "$f" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$archs" != "$expected" ]]; then echo "  wrong architectures ($archs): ${f#$APP/}"; status=1; fi
done < <(macho_files "$APP")
echo "  $count Mach-O files, all [$expected]"
for required in Contents/MacOS/Jit Contents/Helpers/jit-git-helper Contents/Resources/git/bin/git \
    Contents/Resources/git/libexec/git-core/git-remote-http Contents/Resources/git/LICENSE \
    Contents/Resources/git/SOURCE.txt; do
    [[ -e "$APP/$required" ]] || { echo "  missing $required"; status=1; }
done
forbidden="$(find "$APP" \( -iname '*TestRig*' -o -iname '*JitBench*' -o -iname '*GitTestKit*' -o -name '*.xctest' \
    -o -name '*.swiftmodule' -o -name '*.dSYM' -o -name '*.p12' -o -name '*.p8' -o -name '.DS_Store' \) -print)"
if [[ -n "$forbidden" ]]; then echo "  development-only content embedded:"; echo "$forbidden" | sed 's/^/    /'; status=1; fi
if strings -a "$APP/Contents/MacOS/Jit" | grep -qE "^(TestRig|JitBench)\b"; then echo "  dev target symbols in Jit"; status=1; fi
[[ $status -eq 0 ]] || die "bundle verification failed"
echo "  ok: architectures, helper, Git runtime, no development-only content"
