# ADR-0020: Updates for V1

- Status: superseded by ADR-0051 (2026-11-11)
- Date: 2026-11-09
- Phase: P7
- Requirements: §19 (no unintended remote requests), §21; Phase 7 design §4.10

## Context
An auto-updater adds a network endpoint, an update-signing key and a dependency (e.g. Sparkle) whose security
Jit would own, plus background requests that §19 forbids by default.

## Options
1. No updater. Releases are announced on the project page; the user downloads the new DMG.
2. Sparkle with an EdDSA-signed appcast, **opt-in** (no check until the user enables it), no system profiling.
3. Sparkle with automatic checks by default — rejected (unintended network requests).

## Decision
V1 ships with **no update mechanism and no network request for updates** (option 1). Help ▸ Jit Help opens the
project page in the user's browser only on an explicit click. Option 2 is a Phase 8 candidate, with its own
ADR covering key custody and appcast hosting.

## Consequences
Users update by hand. Security fixes (including bundled-Git CVEs, ADR-0019) reach users only when they
download a new release, so the release notes must call out security fixes clearly.
