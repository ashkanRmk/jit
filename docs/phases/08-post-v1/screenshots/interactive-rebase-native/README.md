# Native interactive rebase acceptance

Verified on 2026-11-19: macOS 27.0.1 (26A434), Xcode 27.2 (27B52), Apple silicon.
Both light/dark XCUITests passed with zero failures or skips. Captures are unmodified native window
screenshots (1180 × 760), including system chrome, from disposable repositories and app support.

Each case clicks the handle, drags Foxtrot from last to first and back to last, reorders with the
keyboard, rewords Bravo with literal multiline text, checks text-editor arrow ownership, cancels the
default confirmation with Return, then explicitly confirms with Tab/Space. Git checks the six subjects,
unchanged tree, original author, active-profile committer and clean worktree.

| Stage | Light | Dark |
|---|---|---|
| After both drag directions (intermediate first/last positions asserted before capture) | [Capture](drag-light.png) | [Capture](drag-dark.png) |
| Native message editing | [Capture](keyboard-light.png) | [Capture](keyboard-dark.png) |
| Successful rewrite and resulting history | [Capture](completed-light.png) | [Capture](completed-dark.png) |

Reproduce with `scripts/testing/native-rebase-acceptance.sh`. Use an unlocked foreground desktop and
leave mouse/keyboard input idle during the run. The script prints its retained `.xcresult` location.
