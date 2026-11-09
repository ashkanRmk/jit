# ADR-0044: Command palette and the single command registry

- Status: accepted
- Date: 2026-11-09
- Phase: P6
- Requirements: §17; design §3.1, §3.2

## Context
⌘K must list every menu command with its shortcut and enabled state, plus branches, files, repositories and
commits, and must never disagree with the menus. The menus were built by hand in `MainMenu`.

## Decision
- `CommandRegistry` (Features/Menus) is the one list of commands: id, title, menu and submenu, first-responder
  selector, key equivalent, separator group, symbol, palette visibility and keywords. `MainMenu.build` creates
  every actionable item from it (dynamic lists — recents, tabs, profiles, recently discarded — stay dynamic);
  each item's `identifier` is the command id. `CommandRegistryTests` proves menu = registry, no shortcut
  conflicts, and standard macOS shortcuts untouched.
- Enabled state comes from the same `validateMenuItem(_:)` the menus use, resolved along the **main window's**
  responder chain (the palette panel is key but never main). Disabled commands are listed with the reason from
  `CommandAvailability.disabledReason(for:)` and never run.
- Sources: commands; local/remote branches and tags (primary: show in graph, ⌘↩: check out through the
  operations flow with its confirmations); changed files (open diff) and tracked files (`git ls-files`, lazy on
  `/` or ≥ 2 characters, bounded, cached per repository revision); open tabs and recents; SHA prefix among
  loaded commits only. Prefix scopes `>` `@` `/` `#` `:`.
- Ranking (`FuzzyMatcher`, `PaletteRanker`): subsequence match with word-start, consecutive-run, prefix and
  first-character bonuses, gap penalty, keyword matches at half weight, recency bonus for the last 5 commands,
  ties by source order then registry order; top 50; runs off the main actor on value snapshots.
- UI: a borderless child `NSPanel`, top edge anchored in the upper part of the window, one `jitGlass`
  container (opaque under Reduce Transparency), system label colours, selection with the accent fill,
  appear 140 ms / dismiss 100 ms opacity only.

## Consequences
- Adding a menu command adds it to the palette automatically; adding a palette-only command is not possible
  by design.
- The design's 4 pt rise on appear was dropped: with the top edge anchored to keep the field still while
  results resize, the fade alone reads better (deviation recorded in progress.md).
