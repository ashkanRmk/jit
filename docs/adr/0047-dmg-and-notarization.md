# ADR-0047: DMG format and notarization flow

- Status: accepted
- Date: 2026-11-09
- Amended: 2026-11-19 for Finder-independent installer packaging
- Phase: P7
- Requirements: §20 steps 7–10; Phase 7 design §3.1, §4.6

## Decision
- **DMG**: HFS+ read-write image converted to a read-only **ULFO** (LZFSE) image named `Jit-<version>.dmg`.
  The installer pairs `Jit.app` with an `Applications` symlink and uses Jit's wordmark and app icon.
  `dmg-layout.json` supplies window dimensions and icon coordinates to the metadata writer and Swift
  background renderer. `tiffutil -cathidpicheck` combines the 1× and 2× backgrounds. The label plates
  support both Finder label colors. The disk uses Jit's `AppIcon.icns` as its volume icon.
- **Layout metadata** is generated on the mounted image with pinned `ds_store` and `mac_alias` wheels.
  The background alias is created per image using the mounted volume's identity. This supports packaging
  without a Finder session. The release validator reopens `.DS_Store` on the final read-only image and
  checks the background alias, icon view, window bounds, icon placement and Applications link target.
- **Signing**: the DMG is signed with the same identity (`codesign --timestamp`).
- **Notarization**: notarize the signed **DMG** (one submission covers the app inside) with
  `xcrun notarytool submit --keychain-profile jit-notary --wait --output-format json`. The JSON is saved per
  DMG SHA-256, so an accepted DMG is not resubmitted. On failure the notary log is fetched and its issues
  printed. Then `xcrun stapler staple` the DMG. Credentials: the owner runs `xcrun notarytool
  store-credentials jit-notary …` once with an App Store Connect API key; the scripts never see the secret.
- **Validation** (`09-validate.sh` → `validation.txt`): SHA-256; DMG signature; `stapler validate`;
  `spctl --assess --type open --context context:primary-signature` on the DMG and `--type execute` on the app
  inside; strict deep signature; runtime flag; architectures; the bundled Git runs from inside the DMG;
  layout files. In ad-hoc mode the ticket and Gatekeeper checks are expected to fail and are recorded that way.

## Status
DMG build and structural validation verified (ad-hoc). Notarization, stapling and Gatekeeper acceptance have
not been run: no credentials (progress.md).
