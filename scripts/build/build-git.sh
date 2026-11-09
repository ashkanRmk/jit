#!/usr/bin/env bash
# Builds the relocatable Git runtime that ships inside Jit.app/Contents/Resources/git (ADR-0019).
#
#   scripts/build/build-git.sh [--force]
#
# Downloads the pinned source tarball into build/git-src, checks its SHA-256 (and its PGP signature when
# gpg is installed and JIT_GIT_VERIFY_SIGNATURE=1), builds it for the release architectures with
# RUNTIME_PREFIX against macOS system libraries only (libcurl, zlib, iconv, CommonCrypto; no Homebrew,
# no Rust, no Perl/Python/Tcl), prunes it to the allowlist below and writes the result to
# build/git-runtime/<version>/git. Idempotent: skips the build when the stamp matches.
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/git-version.env"

FORCE=0
case "${1:-}" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    "") ;;
    *) die "unknown option '$1'" ;;
esac

ARCHS="${JIT_ARCHS:-arm64}"
SRC_DIR="$REPO_ROOT/build/git-src"
OUT_ROOT="$REPO_ROOT/build/git-runtime/$GIT_VERSION"
OUT="$OUT_ROOT/git"
TARBALL="$SRC_DIR/git-$GIT_VERSION.tar.xz"
STAMP_VALUE="$GIT_VERSION $GIT_TARBALL_SHA256 $ARCHS $(shasum -a 256 "$0" | cut -c1-16)"

if [[ $FORCE -eq 0 && -f "$OUT_ROOT/.stamp" && "$(cat "$OUT_ROOT/.stamp")" == "$STAMP_VALUE" && -x "$OUT/bin/git" ]]; then
    info "Git $GIT_VERSION runtime is up to date: $OUT"
    exit 0
fi

require_xcode
mkdir -p "$SRC_DIR"

# --- Fetch and verify -------------------------------------------------------------------------------
if [[ ! -f "$TARBALL" ]]; then
    info "Downloading git-$GIT_VERSION.tar.xz"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TARBALL.partial" "$GIT_SOURCE_URL/git-$GIT_VERSION.tar.xz"
    mv "$TARBALL.partial" "$TARBALL"
fi
actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[[ "$actual" == "$GIT_TARBALL_SHA256" ]] || die "SHA-256 mismatch for $TARBALL: expected $GIT_TARBALL_SHA256, got $actual"
info "SHA-256 verified ($actual)"
if [[ "${JIT_GIT_VERIFY_SIGNATURE:-0}" == 1 ]]; then
    command -v gpg >/dev/null || die "JIT_GIT_VERIFY_SIGNATURE=1 needs gpg (brew install gnupg)"
    curl -fsSL --proto '=https' -o "$SRC_DIR/git-$GIT_VERSION.tar.sign" "$GIT_SOURCE_URL/git-$GIT_VERSION.tar.sign"
    xz -dc "$TARBALL" | gpg --status-fd 1 --verify "$SRC_DIR/git-$GIT_VERSION.tar.sign" - 2>/dev/null \
        | grep -q "VALIDSIG $GIT_SIGNING_KEY_FINGERPRINT" || die "PGP signature check failed"
    info "PGP signature verified ($GIT_SIGNING_KEY_FINGERPRINT)"
fi

# --- Build each architecture --------------------------------------------------------------------------
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN=26.0
MAKE_FLAGS=(
    prefix=/ RUNTIME_PREFIX=YesPlease
    NO_HOMEBREW=YesPlease NO_DARWIN_PORTS=YesPlease NO_FINK=YesPlease
    NO_RUST=YesPlease NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease
    NO_INSTALL_HARDLINKS=YesPlease INSTALL_SYMLINKS=YesPlease
)
JOBS="$(sysctl -n hw.ncpu)"
STAGES=()
for arch in $ARCHS; do
    work="$SRC_DIR/work-$arch"
    stage="$SRC_DIR/stage-$arch"
    rm -rf "$work" "$stage"
    mkdir -p "$work"
    tar -xJf "$TARBALL" -C "$work" --strip-components 1
    info "Building Git $GIT_VERSION ($arch)"
    flags="-arch $arch -mmacosx-version-min=$MIN -isysroot $SDK"
    (cd "$work" && make -j"$JOBS" "${MAKE_FLAGS[@]}" CFLAGS="-O2 $flags" LDFLAGS="$flags" \
        DESTDIR="$stage" install >"$SRC_DIR/build-$arch.log" 2>&1) \
        || { tail -30 "$SRC_DIR/build-$arch.log" >&2; die "Git build failed ($arch); log: $SRC_DIR/build-$arch.log"; }
    STAGES+=("$stage")
done

# --- Assemble (lipo when more than one architecture) -------------------------------------------------
rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT"
cp -R "${STAGES[0]}" "$OUT"
if [[ ${#STAGES[@]} -gt 1 ]]; then
    while IFS= read -r rel; do
        inputs=()
        for stage in "${STAGES[@]}"; do inputs+=("$stage/$rel"); done
        lipo -create "${inputs[@]}" -output "$OUT/$rel"
    done < <(cd "$OUT" && find . -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
fi

# --- Prune to the allowlist ----------------------------------------------------------------------------
# Kept: the git binary, every builtin's dashed name (symlinks to git), smart/dumb HTTP(S) transport, the
# shell helpers that merge strategies, rebase and submodule use. Everything else (daemon, shell, scalar,
# imap/send-email, svn/cvs/p4, instaweb, mergetool/difftool, filter-branch, completions) is removed.
core="$OUT/libexec/git-core"
KEEP_FILES=(
    git-remote-http git-http-fetch git-sh-i18n--envsubst
    git-sh-setup git-sh-i18n git-merge-octopus git-merge-one-file git-merge-resolve git-submodule
)
for entry in "$core"/* "$core"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ -L "$entry" ]]; then
        target="$(readlink "$entry")"
        # builtin aliases (-> git) and the https alias of remote-http stay
        [[ "$target" == git || "$target" == */bin/git || "$name" == git-remote-https ]] && continue
        rm -f "$entry"; continue
    fi
    [[ "$name" == git ]] && continue
    keep=0
    for k in "${KEEP_FILES[@]}"; do [[ "$name" == "$k" ]] && keep=1; done
    [[ $keep -eq 1 ]] || rm -rf "$entry"
done
# One real git binary: libexec/git-core/git becomes a symlink to bin/git.
rm -f "$core/git"
ln -s ../../bin/git "$core/git"
# bin/: git plus the transport aliases a local (file://) clone may exec.
for entry in "$OUT/bin"/*; do
    name="$(basename "$entry")"
    case "$name" in
        git) ;;
        git-upload-pack|git-receive-pack|git-upload-archive) rm -f "$entry"; ln -s git "$entry" ;;
        *) rm -rf "$entry" ;;
    esac
done
rm -rf "$OUT/share/bash-completion" "$OUT/share/perl5" "$OUT/share/gitweb" "$OUT/share/gitk" "$OUT/share/git-gui"
# Minimal templates: description, info/exclude and an empty hooks/ (tools that install hooks expect the
# folder to exist); the inert *.sample hooks are dropped.
rm -f "$OUT/share/git-core/templates/hooks/"*.sample
# Strip local symbols before signing.
while IFS= read -r macho; do strip -x "$macho"; done \
    < <(find "$OUT" -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)

# --- System config, license, provenance ----------------------------------------------------------------
mkdir -p "$OUT/etc"
cat >"$OUT/etc/gitconfig" <<'CONF'
# System configuration of the Git bundled with Jit (ADR-0019). Intentionally empty: the bundled Git
# does not inherit any other Git's system configuration (e.g. Apple's credential.helper=osxkeychain).
# Your ~/.gitconfig and each repository's .git/config are read as usual.
CONF
work0="$SRC_DIR/work-$(echo "$ARCHS" | awk '{print $1}')"
cp "$work0/COPYING" "$OUT/LICENSE"
echo "$GIT_VERSION" >"$OUT/VERSION"
cat >"$OUT/SOURCE.txt" <<SRC
Git $GIT_VERSION is distributed with Jit under the GNU General Public License, version 2 (see LICENSE).

Corresponding source:
  $GIT_SOURCE_URL/git-$GIT_VERSION.tar.xz
  SHA-256 $GIT_TARBALL_SHA256
Build script: scripts/build/build-git.sh and scripts/build/git-version.env in the Jit source repository
(https://github.com/ashkanRmk/jit), unmodified Git sources, built with:
  make ${MAKE_FLAGS[*]}
Each Jit release also publishes this exact tarball and build script next to the DMG.

Written offer: for at least three years from the date you received this copy of Jit, the Jit maintainers
will provide the complete corresponding source code of this Git build, on request, for no more than the
cost of physically performing the distribution. Open an issue at https://github.com/ashkanRmk/jit/issues.
SRC

echo "$STAMP_VALUE" >"$OUT_ROOT/.stamp"
info "Git runtime ready: $OUT ($(du -sh "$OUT" | cut -f1), $(cd "$OUT" && find . -type f | wc -l | tr -d ' ') files)"
