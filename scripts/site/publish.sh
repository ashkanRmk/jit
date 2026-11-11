#!/usr/bin/env bash
# Builds the website (site/) locally for a release and publishes it to the `gh-pages` branch, which GitHub Pages
# serves as is. No GitHub Actions and no GitHub API: the download link, size and version come from the local
# release build in build/release/<version>/. Mandatory after every release (docs/release.md §2).
#
#   scripts/site/publish.sh                  # version from Version.xcconfig
#   scripts/site/publish.sh --version 0.0.5
#   scripts/site/publish.sh --dry-run        # build into build/site/ only, push nothing
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../build" && pwd)/common.sh"

VERSION=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die "unknown argument: $1 (use --version X.Y.Z, --dry-run)" ;;
    esac
done
if [[ -z "$VERSION" ]]; then
    VERSION="$(awk -F' = ' '$1 == "MARKETING_VERSION" { print $2; exit }' "$MACOS_DIR/App/Config/Version.xcconfig")"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not X.Y.Z"

REPO_SLUG="ashkanRmk/jit"
DMG="$REPO_ROOT/build/release/$VERSION/Jit-$VERSION.dmg"
[[ -f "$DMG" ]] || die "$DMG not found: build the release first (scripts/release/release.sh --version $VERSION --adhoc)"
SIZE="$(stat -f %z "$DMG")"
URL="https://github.com/$REPO_SLUG/releases/download/$VERSION/Jit-$VERSION.dmg"
PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SIZE_MB="$(awk -v s="$SIZE" 'BEGIN { printf "%.1f", s / 1e6 }')"

# 1. Build.
OUT="$REPO_ROOT/build/site"
info "Building the site for Jit $VERSION into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a --exclude release.json --exclude .DS_Store "$REPO_ROOT/site/" "$OUT/"
printf '{"published":"%s","size":%s,"tag":"%s","url":"%s","version":"%s"}\n' \
    "$PUBLISHED" "$SIZE" "$VERSION" "$URL" "$VERSION" > "$OUT/release.json"
# The same link and label in the HTML itself, so the page is right before (or without) JavaScript.
sed -i '' \
    -e "s#href=\"https://github.com/$REPO_SLUG/releases\" data-download#href=\"$URL\" data-download#g" \
    -e "s#<span data-download-label>Download Jit</span>#<span data-download-label>Download Jit $VERSION</span>#g" \
    -e "s#<p class=\"fine\" data-release-meta>macOS 26 or later, Apple silicon</p>#<p class=\"fine\" data-release-meta>$SIZE_MB MB. macOS 26 or later, Apple silicon</p>#g" \
    "$OUT/index.html"
grep -q "$URL" "$OUT/index.html" || die "the download link was not written into index.html (markup changed?)"
touch "$OUT/.nojekyll"  # serve files as they are
cat "$OUT/release.json"

if [[ "$DRY_RUN" == 1 ]]; then
    info "Dry run: nothing pushed. Open $OUT/index.html to check."
    exit 0
fi

# 2. Publish: one commit on top of the current gh-pages (history kept, never force-pushed).
ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/jit-site.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
git -C "$STAGE" init -q
if git -C "$STAGE" fetch -q --depth 1 "$ORIGIN" gh-pages 2>/dev/null; then
    git -C "$STAGE" reset -q --soft FETCH_HEAD
fi
rsync -a "$OUT/" "$STAGE/" --exclude .git
git -C "$STAGE" add -A
if git -C "$STAGE" rev-parse -q --verify HEAD >/dev/null && git -C "$STAGE" diff --cached --quiet; then
    info "gh-pages already shows this site; nothing to publish"
    exit 0
fi
SOURCE="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
git -C "$STAGE" commit -q -m "site: Jit $VERSION (from $SOURCE)"
git -C "$STAGE" push -q "$ORIGIN" HEAD:refs/heads/gh-pages
info "Published to gh-pages: https://ashkanrmk.github.io/jit/ (GitHub Pages takes about a minute)"
