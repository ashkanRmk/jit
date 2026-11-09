# Phase 0 screenshots

**How these were made:** debug builds of `Jit.app` launched with
`-JitAppearance light|dark -JitOpen <path> -JitSnapshot <file>` (gallery: `-JitShowGallery YES
-JitGallerySection <name> -JitSnapshotWindow design-system`). The app renders its own window's view
hierarchy to PNG (`macos/App/DebugLaunchActions.swift`), downscaled to 1400 px.

**Limitation — read before reviewing glass:** these are *in-app renders*, not screen captures. The
opaque content layer (surfaces, text, cards, rows, lanes, diff colors) is drawn exactly. **Liquid Glass
is composited by the window server and does not appear correctly**: glass buttons (`Open Repository…`,
`Open Another…`, gallery buttons), the toolbar button background, the sidebar material and the
segmented control show as missing or grey. Real screen captures were not possible in the Phase 0
session (no Screen Recording permission for the agent's processes); glass, Reduce Transparency and
Increase Contrast captures are listed as carry-overs in `../progress.md`.

| File | State |
|---|---|
| `foundation-empty-{light,dark}.png` | launch, no repository |
| `foundation-loaded-{light,dark}.png` | regular repository |
| `foundation-loaded-worktree-light.png` | linked worktree (shows main repository) |
| `foundation-loaded-bare-light.png` | bare repository |
| `foundation-loaded-unborn-light.png` | fresh `git init`, no commits |
| `foundation-error-{light,dark}.png` | not a Git repository |
| `foundation-error-permission-light.png` | unreadable folder |
| `design-system-<section>-{light,dark}.png` | gallery sections |
