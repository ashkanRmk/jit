#!/usr/bin/env bash
# §20 step 4: builds (or reuses) the pinned, pruned Git runtime and embeds it at
# Jit.app/Contents/Resources/git (ADR-0019).
source "$(dirname "$0")/lib.sh"
source "$REPO_ROOT/scripts/build/git-version.env"
step "02 bundle Git $GIT_VERSION"
[[ -d "$APP" ]] || die "run 01-build-app.sh first"
JIT_ARCHS="$JIT_ARCHS" "$REPO_ROOT/scripts/build/build-git.sh"
RUNTIME="$REPO_ROOT/build/git-runtime/$GIT_VERSION/git"
DEST="$APP/Contents/Resources/git"
rm -rf "$DEST"
ditto "$RUNTIME" "$DEST"
[[ "$("$DEST/bin/git" --version)" == "git version $GIT_VERSION" ]] || die "embedded Git does not run"
[[ "$("$DEST/bin/git" --exec-path)" == "$DEST/libexec/git-core" ]] || die "embedded Git exec-path is not inside the app"
echo "Git $GIT_VERSION → $DEST ($(du -sh "$DEST" | cut -f1))"
