# Workspace sizing and branch cleanup

Implemented on 2026-11-18; included in the [0.0.9 test build](../../releases/v0.0.9.md).
Acceptance plan: [P8.ux.5](specs/P8.ux.5-workspace-sizing-and-branch-cleanup.md).

## Behavior

- Dragged graph widths survive fitting, refresh and serialization. The branch column can narrow to
  40 logical points. Long labels truncate; horizontal scrolling handles large preferred widths.
- The Remote section contains Git's cached remote-tracking refs. Fetch now prunes by default, the remote
  row has a refresh button, and Fetch All actually targets all remotes rather than selecting origin.
- Individual local branches without a cached remote counterpart show a trash button. Existing deletion
  confirmation and unmerged-commit review remain in use.
- Local and Remote header trash buttons prepare bulk cleanup. Refresh/prune all remotes, read live heads
  from every remote, and protect same-named remote branches and differently named configured upstreams,
  even outside narrow fetch refspecs. An unavailable remote aborts preparation.
- Bulk confirmation lists the exact merged local branches to delete. Current/worktree and unmerged
  branches are retained. Verify the confirmation token, recheck live remote eligibility and validate the
  repository snapshot before deletion. Merged branches are found in one Git query, avoiding one process
  per branch. An unborn HEAD keeps local branches. No remote branch is deleted by cleanup.
- View menu zoom is persisted at 75/80/90/100/110/125/150%. ⌘+ and ⌘= zoom in, ⌘− zooms out, ⌘0 resets.
  Code-only text sizing remains available without conflicting shortcuts. System menus and window controls
  keep native sizing. The workspace scrolls when it cannot fit at the chosen scale.
- Native drawing uses the canvas scale. SwiftUI hosting boundaries cancel that transform and apply it
  inside SwiftUI, preserving gesture coordinates. Flexible header widths remain independent of their
  previous layout so zooming back out cannot push the split view or sidebar outside the window.

## Verification

Real temporary repositories and local bare remotes cover prune, merged/local-only cleanup, unmerged and
worktree protection, renamed upstreams, multiple remotes, narrow refspecs, stale confirmation, newly
published branches, unavailable remotes and confirmation mismatch. The UI tests exercise actual graph
mouse dragging, deletion confirmation/cancel/confirm, zoom shortcuts and persisted preferences.

Layout coverage renders light and dark at 960/1180/1600-point windows and 75/100/150% zoom (18 combinations).
Assertions check physical scale, split-pane separation, toolbar exclusion, left canvas alignment and split
view containment. A pointer regression sends mouse events at the drawn SwiftUI button at all three scales.
Set `JIT_UI_EVIDENCE_DIR` to export the PNGs from `WorkspaceInteractionTests`.

The full package run executed 932 tests. Its only serial-run failures were seven credential/signature tests
(10 assertions): this Command Line Tools version loads tests into Apple's signed `swift-test` process,
while those tests expect an ad-hoc development host. All 14 credential/signature-related tests pass when
the same built test bundle is loaded into a temporary unsigned Swift Testing launcher. No authentication
or signature protections were changed.

After the final sizing fixes, 230 UI/design-system/branch-cleanup tests in 48 suites passed. The final
cleanup and interaction regression run passed all 13 tests, including an unborn HEAD and batched merged-ref
lookup. The Features target compiled successfully. Formatting/architecture lint and `git diff --check`
passed. All 18 light/dark layout captures were generated and reviewed; the final live pass confirmed Fetch
at 150% and restored the sidebar and graph correctly at 100%.

During initial verification, the normal full-Xcode app build was unavailable: Xcode's license was not
accepted and XcodeGen was absent. Release verification below supersedes those initial toolchain limits.
A temporary Debug QA app was linked directly from the package objects and the real app entry sources with
the available macOS 26.5 SDK; it was exercised against an isolated temporary repository and bare remote.
The live checks cover pruning, both confirmation sheets, zoom shortcuts, pointer targets and diff navigation.

The Command Line Tools also lack SwiftUI's macro plugin. Three existing `@Entry` environment properties
use equivalent explicit EnvironmentKey implementations so the available SDK can compile the package.

For this host, package compilation used the native SwiftPM driver, the macOS 26.5 SDK, the installed Testing
framework search path and its TestingMacros plugin. Standard development commands remain documented in README.

## Zoom sharpness follow-up

The enlarged SwiftUI text and SF Symbols used a visual scale of their original glyphs, making the inspector,
file paths and command bar softer than native controls. Typography now resolves the actual destination font
size. A single-child layout reports the original logical dimensions and preserves first/last text baselines;
an inverse glyph transform cancels the enclosing canvas transform. Nested text styles apply that layout
compensation only once. No offscreen drawing group or bitmap enlargement is introduced.

The hosting boundary passes the workspace zoom through the design-system environment. Token typography,
SF Symbols, file-path fonts, commit fields, avatar initials and profile initials use the same renderer.
Regression coverage reads the resolved native font sizes at all seven zoom levels, checks nested styles and
multiline first-baseline alignment, and clicks styled buttons at every zoom level. The existing 18 light/dark
size/zoom combinations are rendered again to check the resulting layout.

Sharpness verification: 233 UI/design-system/cleanup tests in 49 suites passed, along with formatting and
architecture lint. The live 150% view was reviewed for inspector headings, author details, file paths and
command-bar symbols; Path/Tree interaction and zoom reset were exercised. The rebuilt QA app remains open
on the repository for review. All seven zoom steps retain correct styled-button pointer targets.
