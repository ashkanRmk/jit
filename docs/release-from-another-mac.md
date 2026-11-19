# Release Jit from another Mac

The free release path requires an Apple silicon Mac running macOS 26 or later and full Xcode 26 or later.
The release Mac builds and publishes. Use the existing encrypted Ed25519 private key on your signing
machine or encrypted offline storage. The official public key comes with the checkout.

## 1. Set up the Mac and clone Jit

Install full Xcode and launch it once to complete setup. Install [Homebrew](https://brew.sh/) if needed.
Adjust the Xcode path below if you installed it somewhere else.

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
brew install gh openssl@3 python xcodegen
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
gh repo clone ashkanRmk/jit
cd jit
git switch main
git pull --ff-only
```

Sign in with a GitHub account that can push to `ashkanRmk/jit`, create releases and update `gh-pages`.
Set up the installer tools in this checkout and point the signing scripts at OpenSSL 3.

```bash
python3 -m venv build/dmg-tools
build/dmg-tools/bin/python3 -m pip install --require-hashes -r scripts/release/dmg-requirements.txt
export JIT_UPDATE_OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
```

## 2. Version, test and build

Choose an unused release version. In `macos/App/Config/Version.xcconfig`, set `MARKETING_VERSION` and
increase `CURRENT_PROJECT_VERSION`. Write `docs/releases/vX.Y.Z.md` and commit the release changes.
Start the build from that clean commit. The examples use `0.1.4`. Substitute your actual version in
each terminal you use.

```bash
version=0.1.4
git status --short
scripts/build/lint.sh
JIT_TEST_SERIAL=1 scripts/build/test-core.sh
scripts/build/test-app.sh
scripts/release/release.sh --version "$version" --adhoc
```

The first build downloads and verifies the pinned Git source, then builds the bundled Git runtime.
Confirm `validation.txt` in `build/release/$version/` reports `PASS`. Open the DMG in Finder and check
the Jit wordmark, the two icons and the arrow. Run the signed-update acceptance on an unlocked desktop
with Developer Tools authorization enabled. The release build itself works from an SSH session.

```bash
scripts/testing/signed-update-acceptance.sh "build/release/$version/stage/Jit.app"
```

## 3. Sign the exact DMG

Copy `Jit-$version.dmg` and `scripts/release/update-signing.sh` to the signing machine. Use the **same
private key used for 0.1.3** so existing Jit installations can verify the update. The signing machine
needs OpenSSL 3 and does not need Xcode or GitHub access. Set `JIT_UPDATE_OPENSSL` to its OpenSSL 3 binary
if `openssl version` reports LibreSSL.

```bash
version=0.1.4
bash ./update-signing.sh sign "$version" "/path/to/Jit-$version.dmg" /path/to/jit-update-key.pem
```

Enter the passphrase in that terminal. Return the two generated files, `.dmg.manifest` and
`.dmg.manifest.sig`, to `build/release/$version/` on the release Mac, beside the original DMG. Prepare
the upload directory.

```bash
scripts/release/10-prepare-publish.sh
```

The script verifies the signature with Jit's committed public key and compares the DMG with the
validated build. A rebuild changes the bytes and requires a new validation and signature. If you
lose the private key, follow the [key replacement guidance](release.md#offline-update-signing).

## 4. Publish and verify

Run these commands from the approved release commit on `main`. The tag must identify the exact commit
used to build the DMG.

```bash
git tag -a "$version" -m "Jit $version"
git push --atomic origin main "refs/tags/$version"
gh release create "$version" "build/release/$version/publish/"* \
  --draft --prerelease --verify-tag --title "Jit $version — test build" \
  --notes-file "docs/releases/v$version.md"
```

Verify the draft contains six assets and compare their GitHub digests with the local files.

```bash
gh api 'repos/ashkanRmk/jit/releases?per_page=30' \
  --jq ".[] | select(.tag_name == \"$version\") | .assets[] | [.name, .digest] | @tsv"
(cd "build/release/$version/publish" && shasum -a 256 ./*)
```

Publish the verified draft and update the download website.

```bash
gh release edit "$version" --draft=false
scripts/site/publish.sh --version "$version"
curl -fsSL 'https://ashkanrmk.github.io/jit/release.json'
```

Confirm the website version and DMG URL match the new release. The ad-hoc-signed DMG may require
**Open Anyway** on first launch. [Release reference](release.md)
