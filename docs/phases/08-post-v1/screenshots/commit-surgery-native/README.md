# Native direct commit actions

Captured on 2026-11-19: macOS 27.0.1 (26A434), Xcode 27.2 (27B52), Apple silicon.
Both direct-action XCUITests passed with zero failures/skips. All ten captures were reviewed.
Window-only XCTest attachments (1180 × 760) use disposable repositories, app support and the Native QA profile.

Each appearance edits Echo's older message using literal multiline text, cancels review with Return
and verifies unchanged HEAD, explicitly saves, edits Foxtrot at HEAD, cancels and explicitly confirms
dropping Bravo, then creates a branch at the previous tip through Reflog. Git assertions check messages,
unchanged edit trees/parents, only Bravo.txt removed, original author/profile committer, clean status and
recovered-before-drop containing Bravo.txt at the exact previous SHA.

| Stage | Light | Dark |
|---|---|---|
| Message editor | [Capture](message-light.png) | [Capture](message-dark.png) |
| Replacement-message review | [Capture](message-review-light.png) | [Capture](message-review-dark.png) |
| Drop confirmation | [Capture](drop-review-light.png) | [Capture](drop-review-dark.png) |
| Completed drop | [Capture](completed-light.png) | [Capture](completed-dark.png) |
| Reflog recovery branch created | [Capture](recovered-light.png) | [Capture](recovered-dark.png) |

Reproduce on an unlocked foreground desktop with Developer Tools authorization enabled:

```bash
scripts/testing/native-rebase-acceptance.sh \
  -only-testing:JitNativeInputUITests/CommitSurgeryNativeAcceptanceTests
```
 Leave the pointer and keyboard idle during the run.
The script prints the retained `.xcresult` location. No full-desktop captures are checked in.
