# Tag management visual evidence

Native captures use a disposable repository/bare remote and isolated app state with a synthetic profile.

- [Light annotation creation with multiline input and push](native-create-light.png)
- [Light sidebar details popover](native-details-light.png)
- [Dark shared details sheet, opened through the palette](native-details-dark.png)
- [Dark remote deletion confirmation](native-delete-remote-dark.png)
- [Dark local deletion and exact recovery object](native-delete-local-dark.png)

Canonical snapshots are in
[`Tests/FeaturesTests/__Snapshots__`](../../../../../macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/):

- `tag-annotated-{light,dark,light-rt,dark-rt}.png`
- `tag-lightweight-{light,dark,light-rt,dark-rt}.png`
- `tag-create-{light,dark}.png`
- `tag-delete-remote-{light,dark}.png`

The `-rt` cases disable transparency. All twelve references were reviewed; two comparison runs passed
after recording the final multiline editor. Native context-menu automation stalled in dark mode, so
dark details and deletion were exercised through the palette. See [report](../../progress-tags.md).
