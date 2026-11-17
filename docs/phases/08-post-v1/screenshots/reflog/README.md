# Reflog visual and native QA evidence

Reviewed 2026-11-18 on macOS 27.2.1 (26B131), Xcode 27.2. These are actual views backed by temporary real
repositories, not product mockups. Canonical visual references live with the regression suite rather
than duplicating the same PNGs in two directories:

- [Reflog light](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/reflog-light.png),
  [dark](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/reflog-dark.png).
- [Lost commits light](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/lost-commits-light.png),
  [dark](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/lost-commits-dark.png).
- [Recovery points light](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/recovery-points-light.png),
  [dark](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/recovery-points-dark.png).
- [Opaque chrome light](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/reflog-light-rt.png),
  [dark](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/reflog-dark-rt.png).

All eight references were inspected. The first review caught an unreachable label wrapping onto an
extra line and poor selected-row secondary-text contrast; both were corrected before re-recording.
The native workbench was also viewed through the window server; row selection plus Down updated the
inspector. Covered graph controls are excluded from accessibility/focus while reflog is open.

A separate ad-hoc QA copy (distinct bundle ID, temporary Application Support) opened a disposable repo.
Native UI steps: select the old amended commit → Create Branch → verify “Switch to it” unchecked → name
`recovered-amend` → Create Branch. The UI showed success, `main` remained current, and the recovered row
no longer had the unreachable marker. [Post-operation Git verification](native-recovery.json) confirms
its exact target, unchanged HEAD, empty staged/tracked diffs and the untouched untracked notes file.

No signing, notarization, live VoiceOver or new XCUITest target is claimed by these checks.
