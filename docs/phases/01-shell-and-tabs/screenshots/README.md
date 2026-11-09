# Phase 1 screenshots

**Real screen captures** (`screencapture -l <window>` / `-R <window bounds>` for popovers and sheets) of the
debug build on macOS 27.2, MacBook Pro M5 Pro, 2026-11-09 — Liquid Glass is captured as the window server
composites it. Appearance forced with `-JitAppearance light|dark`; state from throwaway fixture
repositories and `JIT_APP_SUPPORT` (fake identity "Ada Lovelace"). Window 1180 × 760 pt at 2×.

| Screen | Files |
|---|---|
| Tab bar | `tabbar-default`, `tabbar-hover` (pointer over the second tab), `tabbar-overflow` (7 tabs), `tabbar-many` (40 tabs) |
| New-tab page | `newtab-empty`, `newtab-recents`, `newtab-missing` (Locate…/Remove row), `newtab-drop` (overlay forced with `-JitShowDropOverlay YES`) |
| Workbench | `workbench-normal` (staged/unstaged/untracked, upstream ↑↓), `workbench-operation` (rebase 2/3 with a conflict), `workbench-worktree`, `workbench-bare`, `workbench-error` (missing folder), `workbench-loading` (Git slowed by a `JIT_GIT_PATH` wrapper; placeholder after 150 ms) |
| Profiles | `profile-indicator`, `profile-none` (warning-tinted capsule), `profile-popover`, `profile-popover-none`, `profile-sheet` |
| Settings | `settings-general`, `settings-profiles` |

Each exists as `-light` and `-dark`. With the system's **Reduce Transparency** on (toggled by the owner, verified by
the script): `tabbar-default-reducetransparency`, `workbench-normal-reducetransparency`,
`newtab-recents-reducetransparency` — opaque `surface.chromeOpaque` tab capsules with hairlines, the selected tab
`accent.muted` with the system accent edge. Increase Contrast: run `scripts/testing/capture-accessibility.sh
increasecontrast` with the setting on (see progress.md).
