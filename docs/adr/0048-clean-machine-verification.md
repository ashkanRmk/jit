# ADR-0048: Clean-machine verification protocol

- Status: accepted (protocol); clean-VM execution pending
- Date: 2026-11-09
- Phase: P7
- Requirements: §24 A–G; Phase 7 design §4.9

## Protocol (what a release needs)
1. Fresh VMs (UTM, tart or Apple's Virtualization sample): macOS 26.0 and the latest macOS, standard user,
   default Gatekeeper, **no Xcode/CLT/Homebrew** (`xcode-select -p` must fail).
2. Get the DMG by download (local HTTP server + Safari), so it carries `com.apple.quarantine`.
3. Open, drag to Applications, launch: only the standard "downloaded from the Internet" confirmation; no CLT
   prompt at any point; `ps` shows Git running from `Jit.app/Contents/Resources/git`.
4. Run §24 A–G with the checklist in `docs/release.md` (expected / observed / evidence / pass-fail). E/F on
   real accounts, or the Phase 5 local rig, clearly labelled. Judge glass visuals on real hardware only.

## What was run for 1.0.0 (owner decision 2026-11-09: local + test rig)
No VM tooling is installed, and the owner chose not to download macOS images. The run was on the release Mac
(macOS 27.2, Xcode and CLT present): the ad-hoc DMG was quarantined by hand, mounted, copied to /Applications
and launched with an isolated `JIT_APP_SUPPORT`. That is evidence for the app's behaviour and for "no
toolchain dependency" (Git resolved to and ran from the bundle). It is **not** evidence of behaviour on a
machine without CLT, or of Gatekeeper acceptance. Both remain open until the protocol above runs on VMs with
a notarized DMG.
