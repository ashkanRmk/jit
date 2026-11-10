# ADR-0050: Author pictures from Gravatar

- Status: accepted
- Date: 2026-11-10
- Phase: post-V1 (0.0.2)
- Requirements: §19 ("no unintended remote requests"), §26 priorities 1 and 5; amends the roadmap note
  "Avatars: deterministic initials placeholders, no network"

## Context
The graph node and the commit inspector showed initials only. The owner asked for real author pictures where
one exists and chose Gravatar as the source (2026-11-10), over the connected GitHub/GitLab accounts and over
initials only.

## Decision
- `Services/AvatarStore` looks an author up at `https://gravatar.com/avatar/<sha256(email)>?s=96&d=404`.
  The key is the SHA-256 of the trimmed, lowercased email — the address itself is never sent. `d=404` makes
  "no picture" an explicit answer.
- **Only for what is on screen.** A lookup starts when a graph node or an inspector person row is drawn and
  the author is unknown. History is never crawled. No timer, no retry, no background refresh (hard rule:
  never poll).
- **Once per author.** Results are kept in memory (256 authors) and in a disk cache
  (`~/Library/Caches/<bundle id>/avatars`, or `<JIT_APP_SUPPORT>/avatars`) for 7 days — pictures as
  `<hash>.img`, "no picture" as an empty `<hash>.none`. A failed lookup (offline, timeout, proxy) is not
  written to disk and is not repeated in the same run.
- **At most 4 requests at a time**, one ephemeral `URLSession` without cookies, credentials or URL cache,
  10 s timeout, responses over 1 MB ignored. The system proxy settings apply; Jit's per-profile proxy and
  CA settings (ADR-0038) are for Git and provider hosts and are not used here.
- **Off switch:** Settings ▸ General ▸ "Show author pictures from Gravatar" (default on). Off: no request
  is made and initials show everywhere.
- **Tests and tools never reach the network:** the store fetches only through a `fetcher` closure that the
  app delegate installs; `AppModel` created by tests has none.
- Authors without a picture keep the initials avatar (same colour and initials as before).

## Consequences
- Jit now makes network requests the user did not start with a Git command. This is disclosed in Settings,
  the README and `docs/security.md`, and can be switched off.
- gravatar.com learns the IP address and the email hashes of authors whose commits were shown. A hash can
  be matched against known addresses; that is the accepted cost of the owner's choice.
- Idle cost is unchanged: nothing runs unless new authors scroll into view.

## Alternatives considered
- **Connected accounts' hosts (GitHub/GitLab API):** no new third party, but only covers hosts with a
  connected account and needs commit → user resolution per provider. Not chosen by the owner.
- **Initials only:** no network; rejected, the request was for real pictures.
