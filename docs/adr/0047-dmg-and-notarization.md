# ADR-0047: DMG format and notarization flow

- Status: accepted
- Date: 2026-11-09
- Phase: P7
- Requirements: §20 steps 7–10; Phase 7 design §3.1, §4.6

## Decision
- **DMG**: HFS+ read-write image → Finder layout → **ULFO** (LZFSE) read-only, `Jit-<version>.dmg`, volume
  `Jit <version>`. Window 640×400 with icon size 128: Jit.app at (170, 190), an `Applications` symlink at
  (470, 190), and a background (`.background/background.tiff`, 1×+2× via `tiffutil -cathidpicheck`) rendered by
  `scripts/release/assets/dmg-background.swift`. The background is a teal surface in the icon's colours with a
  frosted plate and a guide arrow, and the label band sits near luminance 0.19, so both of Finder's label
  colours (black in light mode, white in dark mode) read at about 4.5:1. The volume icon is the app's
  `AppIcon.icns`.
- **Layout by AppleScript at build time**, not a committed `.DS_Store`: a stored `.DS_Store` records the volume
  name, which contains the version. This needs Finder automation permission once on the release machine;
  `JIT_DMG_LAYOUT=0` skips it. Finding: Finder deletes an existing `.VolumeIcon.icns` while it writes the layout,
  so the volume icon is added after the Finder pass.
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
