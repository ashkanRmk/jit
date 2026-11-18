# Reset visual evidence

Native sheets captured from the isolated debug app on macOS 27.2.1:

- [Hard reset, light](native-hard-light.png)
- [Hard reset, dark](native-hard-dark.png)

Canonical offscreen references live in
[`Tests/FeaturesTests/__Snapshots__`](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__):
`reset-stash`, `reset-discard`, `reset-keep`, `reset-blocked` in light/dark, plus `reset-stash` in
light/dark opaque chrome (`-rt`). All ten were visually reviewed and verified twice after recording.

The real-window workflow also checked default Return cancellation, stash toggle warnings, successful
stash/reset, Reflog recovery into a branch and applying the retained stash. See [report](../../progress-reset.md).
