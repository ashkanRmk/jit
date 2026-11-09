# ADR-0034: Remote URL → web URL mapping

- Status: accepted
- Date: 2026-11-09
- Phase: P4

## Decision
Pure function `WebLink.map(remoteURL:target:)` for github.com (exactly owner/repo) and gitlab.com (nested
groups, `/-/commit`, `/-/tree`); https, ssh://, scp-like; user, port and `.git` stripped; branch names
percent-encoded per segment. Unknown hosts → `nil` → no menu item. Remote choice: the upstream's remote, else
`origin`, else the first. Never makes a network request. Self-managed hosts arrive with Phase 5 server configs.
