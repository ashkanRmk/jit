> Source requirements for Jit, provided by the project owner on 2026-11-08. Do not edit — record changes as ADRs or in docs/roadmap.md. Section numbers (§N) are referenced throughout the docs.

---

# Build a Premium, Ultra-Lightweight Native macOS Git Client

## 0. Your Role and Mission

You are a principal macOS engineer, Rust systems programmer, Git internals specialist, UI/UX designer, security engineer, and performance optimization expert.

Your task is to **design and build a production-quality native macOS Git client**.

This is a real desktop application, not a prototype, concept, mockup, or web application packaged as a desktop app.

The product must combine:

1. An exceptionally beautiful, premium macOS user experience.
2. Extremely low memory and CPU consumption.
3. Near-zero resource utilization when idle.
4. Fast cold startup and instant-feeling interactions.
5. A powerful, visually beautiful Git commit graph.
6. A first-class diff viewer with line-level Git operations.
7. Visual three-way merge-conflict resolution.
8. Multiple Git hosting accounts and manually selectable Git profiles.
9. Reliable, predictable Git operations.
10. Signed and notarized macOS distribution.

**The visual quality and performance are first-class product requirements, not polish to add after the application works.**

The supplied screenshots are functional references showing Git capabilities and interaction patterns. They are NOT the target visual design.

Create an original visual identity. Do not reproduce the screenshots' branding, colors, components, spacing, graph styling, or overall visual language.

The result should feel like a carefully designed commercial macOS application.

---

# 1. Confirmed Product Decisions

These requirements are final. Do not ask to reconfirm them.

| Decision | Requirement |
|---|---|
| Platform | Native macOS |
| UI | SwiftUI + AppKit |
| Git engine | Rust |
| Swift/Rust bridge | UniFFI |
| Web frontend | Not allowed |
| Electron/Tauri | Not allowed |
| Git providers | GitHub.com, GitLab.com, GitLab Self-Managed |
| Provider scope | Git operations and remote repository browsing only |
| Git profiles | One globally selected active profile |
| Authentication | SSH, Personal Access Tokens, browser-based OAuth |
| Diff | File, hunk, and line-level operations |
| Conflicts | Native visual conflict resolution |
| Initial scope | Everyday Git workflows, excellent graph and diff |
| Appearance | Premium native light/dark themes |
| Self-hosted support | Custom CA certificates, system VPN, proxy settings |
| Distribution | Signed, notarized DMG |
| Resource usage | Exceptionally lightweight, almost zero activity when idle |

Use macOS 14 or later as the initial deployment target unless a documented compatibility concern justifies a different baseline.

Target Apple Silicon first, while planning for universal Apple Silicon/Intel distribution.

Use the latest stable, mutually compatible development toolchain available in the environment. Verify library versions and APIs before implementing.

---

# 2. Product Philosophy

The application must follow these principles.

## 2.1 Native-first

- Use SwiftUI for application structure, dialogs, forms, toolbar, settings, and standard interactions.
- Use AppKit where it provides better performance, more precise layout, richer editing, or better desktop behavior.
- Use native macOS menus, context menus, sheets, popovers, keyboard shortcuts, file dialogs, and window management.
- Respect system appearance, accessibility, window activation, and Reduce Motion settings.
- Avoid an embedded browser or JavaScript rendering engine for the application UI.

## 2.2 Performance-first

- Do not load data the user cannot see.
- Do not repeatedly fetch or parse unchanged repository state.
- Do not re-render entire commit histories because one branch changed.
- Never poll Git continuously while the application is idle.
- Do not keep unnecessary background threads or tasks running.
- Avoid creating large in-memory object graphs.
- Prefer streams, bounded batches, virtualization, and incremental updates.
- Avoid runtime animations that continue when nothing is changing.
- Measure every meaningful optimization.

## 2.3 Correctness-first

Git correctness is more important than clever implementation.

Never risk corrupting repository state to improve performance.

Prefer established Git semantics over manually reimplementing complex Git behavior.

All destructive actions must be explicit, understandable, and safe.

## 2.4 Simplicity-first

Avoid:

- Unnecessary abstraction layers.
- Large dependency trees.
- Duplicated state-management mechanisms.
- Multiple competing Git backends without a strong reason.
- Premature generalization.
- Microservices, local servers, databases, or background daemons without demonstrated need.
- Complex design patterns where a straightforward solution is sufficient.

Use a modular monolith with clear responsibilities.

---

# 3. Premium Visual Design — Critical Requirement

You must act as a highly experienced product designer, not merely a programmer assembling stock components.

The application must have a distinctive design language and exceptional attention to detail.

## 3.1 Design Direction

Create a visual identity inspired by premium developer tools and beautifully crafted native Mac software.

Desired characteristics:

- Luxurious but restrained.
- Minimal yet information-dense.
- Technical without feeling industrial or outdated.
- Elegant typography.
- Refined spacing and alignment.
- Beautifully balanced contrast.
- Sophisticated colors.
- Soft, controlled visual depth.
- Carefully polished hover and selection states.
- Calm, fluid interactions.
- Excellent readability during long development sessions.

Avoid:

- Generic admin dashboards.
- Excessive rounded cards.
- Neon cyberpunk styling.
- Overly colorful Git graphs.
- Thick borders everywhere.
- Excessive translucency or blur.
- Unnecessary gradients.
- Large decorative illustrations.
- Excessive toolbar buttons.
- Flashy animations.
- UI copied from the reference screenshots.

The design must feel original and cohesive.

## 3.2 Design System

Create an actual reusable design system with centralized tokens.

Include:

- Light and dark semantic colors.
- Surface hierarchy.
- Accent colors.
- Typography scales.
- Spacing scales.
- Corner-radius scales.
- Border treatments.
- Shadows.
- Focus indicators.
- Hover and pressed states.
- Selection styles.
- Animation durations.
- Animation curves.
- Icon sizing.
- Panel dimensions.
- Density settings.

Use SF Pro for the interface and SF Mono for Git SHAs, file paths where appropriate, and source code.

Use SF Symbols where suitable. Custom vector icons are acceptable when they materially improve the product.

Use semantic colors instead of hardcoding colors inside individual views.

## 3.3 Theme Direction

Light theme:

- Refined warm-neutral or mineral-white surfaces.
- Carefully differentiated panels.
- Deep graphite typography.
- Subtle borders.
- Elegant accent colors.
- Excellent code-diff contrast.

Dark theme:

- Rich graphite or charcoal backgrounds.
- Layered surfaces with subtle luminance differences.
- Soft but highly readable text.
- Muted, sophisticated accent colors.
- No unnecessary glowing borders.
- Excellent contrast without making the application harsh.

The themes must be designed independently, not simply produced by inverting colors.

Support:

- Follow System.
- Light.
- Dark.

Persist the appearance preference.

Ensure that syntax highlighting, diff highlights, graph lanes, badges, menus, and dialogs are equally polished in both themes.

## 3.4 Micro-interactions

Implement lightweight, purposeful micro-interactions.

Examples:

- Subtle tab selection transitions.
- Smooth sidebar expansion.
- Delicate button hover states.
- Refined profile menu appearance.
- Animated commit selection.
- Short transitions between graph and diff states.
- Elegant drag-and-drop feedback.
- Minimal success feedback after staging or committing.
- Small progress indicators during fetch or push.

Suggested interaction durations:

- Hover: approximately 80–140 ms.
- Selection: approximately 120–180 ms.
- Panel transitions: approximately 160–240 ms.

Treat these as design guidelines, not mandatory timing constants.

Requirements:

- Prefer native animation APIs.
- Avoid perpetual animations.
- Avoid expensive blur or shadow animation.
- Avoid animating enormous view hierarchies.
- Disable unnecessary animations during bulk graph updates.
- Respect Reduce Motion.
- Never trade smooth scrolling for visual decoration.
- No animation should consume CPU after it completes.

## 3.5 Design Validation

Before implementing every major interface:

1. Define the user interaction.
2. Identify the visual hierarchy.
3. Design empty, loading, normal, and error states.
4. Implement a native version.
5. Inspect rendered screenshots or previews when available.
6. Check light and dark appearances.
7. Review spacing, typography, and alignment.
8. Measure responsiveness.
9. Refine before moving on.

Do not consider a screen complete simply because it compiles.

---

# 4. Main Application Layout

Create a flexible multi-pane native desktop layout.

The application should have these major regions.

## 4.1 Repository Tab Bar

Located at the top.

Requirements:

- Multiple repository tabs.
- Repository name and subtle status indicator.
- Active tab styling.
- Close button.
- Drag to reorder tabs.
- Horizontal overflow handling.
- Middle-click to close where appropriate.
- Restore previously opened repositories.
- Remember tab order.
- Remember tab-specific UI state.
- Keyboard switching between tabs.
- Clear global Git profile indicator.

Inactive repositories must not continuously consume CPU.

## 4.2 New Tab Experience

Clicking the plus button opens a polished new-tab experience.

Offer:

- Open an existing local repository.
- Clone from URL.
- Browse GitHub repositories.
- Browse GitLab.com repositories.
- Browse self-hosted GitLab repositories.
- Recently opened repositories.

The new-tab page should be beautiful, minimal, and immediately useful.

Support drag-and-drop of a repository folder into the application.

## 4.3 Left Navigator

A collapsible sidebar for repository navigation.

Include:

- Local branches.
- Remote branches.
- Tags.
- Current branch.
- Grouping by branch naming hierarchy.
- Branch filter/search.
- Expand/collapse groups.
- Local versus remote status.
- Tracking/upstream information.
- Checkout actions.
- Branch context menus.

When appropriate, show worktrees and stashes once their functionality is implemented.

The sidebar must support keyboard navigation and large branch collections.

## 4.4 Main Git Graph

The visual center of the application.

It must support an excellent interactive Git history experience.

## 4.5 Right Inspector / Workbench

A configurable panel showing:

- Working directory.
- Staged files.
- Unstaged files.
- Selected commit details.
- Diff viewer.
- File history.
- Blame.
- Conflict resolution.
- Commit composer.

Allow the user to resize the panel and remember its dimensions.

Do not force an overly narrow diff view.

Provide a focused diff mode that can expand the diff editor across the main content area.

## 4.6 Layout Persistence

Persist:

- Open tabs.
- Active tab.
- Sidebar width.
- Inspector width.
- Expanded sidebar groups.
- Selected commit where appropriate.
- History scroll position when practical.
- Diff mode.
- Theme.
- Global active Git profile.

Restore the application without blocking initial window presentation.

---

# 5. Git Graph — Flagship Feature

The graph is one of the most important features of this product.

It must look beautiful and remain fast for large repositories.

## 5.1 Core Graph Features

Implement:

- Commit nodes.
- Parent-child edges.
- Merge commits.
- Merge connection curves.
- Colored branch lanes.
- Stable lane colors.
- Branch labels.
- Remote tracking labels.
- Tag labels.
- Author avatars or graceful placeholders.
- Commit messages.
- Commit timestamps.
- Commit SHAs.
- Current HEAD indicator.
- Detached HEAD representation.
- Diverged branches.
- A virtual WIP/working-directory node.
- Selected and hovered commit states.
- Search/filter controls.
- Commit details on selection.

Graph lines must be clean, aligned, visually balanced, and readable.

Avoid excessive visual noise.

## 5.2 Graph Rendering

Use a virtualized native implementation.

Investigate an AppKit-based collection/list with custom graph drawing, or a custom AppKit graph surface that renders only the visible region.

Requirements:

- Do not create a SwiftUI view for every historical commit.
- Do not maintain one graphical layer per commit for the full history.
- Render only visible rows and a small overscan region.
- Use efficient native drawing.
- Cache stable lane geometry.
- Reuse visible row views.
- Avoid full-layout recomputation.
- Support smooth scrolling.
- Handle graph pagination without distracting visual jumps.

The lane layout algorithm should be deterministic and tested against complex commit graphs.

Support:

- Linear history.
- Multiple merges.
- Octopus merges where applicable.
- Long-lived branches.
- Crisscross merges.
- Rebased history.
- Very large histories.

## 5.3 History Loading

Load commit history incrementally.

Start with a bounded initial batch and fetch additional history near the visible boundary.

Do not load 100,000 commits at startup.

Use cancellable background operations.

Keep memory bounded independently of total repository history where possible.

## 5.4 Graph Interactions

Support:

- Selecting commits.
- Inspecting commit details.
- Opening changed files.
- Searching messages, SHAs, authors, and references.
- Filtering branch history.
- Pinning important branches to the left.
- Solo/focus mode for a branch.
- Comparing selected commits.
- Comparing a commit with the working directory.
- Copying commit SHA.
- Copying branch name.
- Copying relevant remote links.
- Viewing tags.

Context menus must be contextual and only offer actions that make sense for the selected object and repository state.

## 5.5 Visual Quality

Create a distinct commit-node and lane design.

Use carefully selected colors rather than bright random colors.

Ensure:

- Stable branch colors.
- Excellent dark-mode appearance.
- Proper contrast.
- Precise node alignment.
- Smooth curves.
- No visual jitter during incremental loading.
- Crisp rendering on Retina displays.
- Readable compact and comfortable density modes.

---

# 6. Working Directory and Commit Composer

## 6.1 Working Directory

Display:

- Unstaged changes.
- Staged changes.
- Untracked files.
- Renamed files.
- Deleted files.
- Modified files.
- Conflicted files.
- File counts.
- Addition/deletion counts.
- File-type icons.

Support:

- Flat path view.
- Directory tree view.
- File filtering.
- File sorting.
- Stage all.
- Unstage all.
- Stage one file.
- Unstage one file.
- Discard file changes with confirmation.
- Open file in the default editor.
- Inspect a file diff.

Status should refresh efficiently after file changes or Git operations.

## 6.2 Commit Composer

Provide:

- Commit summary.
- Optional commit description.
- Clearly visible staged change count.
- Commit button.
- Commit validation.
- Amend previous commit.
- Commit author/profile indication.
- Explicit error messages.
- Keyboard shortcuts.
- Native loading and success feedback.

Display the currently selected global Git profile and email.

Do not allow accidental commits using an unintended identity.

If no valid profile is selected, present a clear resolution path.

Use the active profile's identity explicitly for the commit operation without rewriting global Git configuration.

If the user switches profiles while an operation is already running, that operation must retain the profile snapshot it started with. New operations must use the newly selected profile.

---

# 7. Native Diff Viewer — Flagship Feature

The diff experience must be one of the best parts of this application.

Implement a real native diff viewer, not a web code editor.

## 7.1 Viewing Modes

Support:

- Unified diff.
- Side-by-side diff.
- Full file view.
- Staged diff.
- Unstaged diff.
- Commit-to-commit diff.
- Commit-to-working-directory comparison.

Allow quick mode switching.

## 7.2 Presentation

Include:

- Syntax highlighting.
- Line numbers.
- Addition and deletion backgrounds.
- Clear gutter indicators.
- Hunk headers.
- Collapsible unchanged regions.
- Search within diff.
- Next/previous change navigation.
- Selected-line highlighting.
- Horizontal scrolling for long lines.
- Optional word-level change highlighting.
- Correct handling of tabs and whitespace.
- Clear empty-file and binary-file states.
- Blame/history actions.
- Edit externally action.

Do not use Monaco, CodeMirror, or a hidden WebView.

Use native AppKit text infrastructure or a custom native diff renderer, selecting the simplest approach that meets performance and correctness requirements.

Avoid highlighting an entire large file on every keystroke or scroll event.

## 7.3 Diff Actions

At file level:

- Stage.
- Unstage.
- Discard changes.

At hunk level:

- Stage selected hunk.
- Unstage selected hunk.
- Discard selected hunk.

At line level:

- Stage selected lines.
- Unstage selected lines.
- Discard selected unstaged lines.
- Keep selected changes.
- Reject selected changes.

Use clear action labels based on context.

"Accept" and "Reject" must never be ambiguous about whether they modify the index, working tree, or merge result.

## 7.4 Safe Partial Staging

This is a critical correctness requirement.

Implement partial staging using validated Git-compatible patches.

For each operation:

1. Capture the relevant index and working-tree state.
2. Build the selected patch correctly.
3. Preserve surrounding context.
4. Validate the patch against the intended target.
5. Check for external modifications since selection.
6. Apply the patch to the correct Git state.
7. Refresh the affected file and diff.
8. Verify the resulting staged/unstaged state.

Use Git's patch-application semantics rather than arbitrary text replacement.

Important distinctions:

- Staging modifies the index.
- Unstaging modifies the index.
- Discarding unstaged changes modifies the working tree.

Do not accidentally affect unrelated changes.

Avoid context-free patches unless a carefully tested case requires them.

Correctly handle:

- Multiple nearby hunks.
- Changes within a single hunk.
- Selected additions and deletions.
- Partially staged files.
- Newly added files.
- Removed files.
- CRLF and LF line endings.
- Files without final newlines.
- Unicode paths.
- Spaces and unusual characters in paths.
- Concurrent file modifications.
- File mode changes.
- Symlinks.
- Renames.
- Binary files.

Where a safe granular operation is unsupported, disable it with a clear explanation rather than attempting a risky workaround.

## 7.5 Loss Prevention

Before destructive changes:

- Detect unsaved or externally changed files.
- Verify the state against which the action was prepared.
- Confirm destructive operations.
- Preserve unrelated staged changes.
- Avoid silent overwrites.
- Offer recovery information where possible.

Tests must prove that partial-stage and discard operations never alter unrelated lines.

---

# 8. Visual Three-Way Conflict Resolution

Implement a beautiful native conflict-resolution interface.

This is included in V1.

## 8.1 Conflict Detection

Detect conflicts during:

- Merge.
- Rebase.
- Cherry-pick.
- Other Git operations that produce unmerged index entries.

Read the actual Git conflict state rather than relying solely on textual conflict markers.

## 8.2 Conflict Editor

Provide:

- Ours pane.
- Theirs pane.
- Editable result pane.
- Optional base/original comparison.
- Conflict block navigation.
- Syntax highlighting.
- Clear conflict regions.
- Line-level conflict visualization.
- Select ours.
- Select theirs.
- Select both, when meaningful.
- Manual editing of result.
- Save resolution.
- Mark resolved.
- Continue or abort the Git operation.

Make Git's "ours" and "theirs" semantics explicit because their meaning can differ during rebases.

Do not universally label them "local" and "remote".

## 8.3 Safety

- Preserve unresolved blocks until explicitly resolved.
- Do not mark a file resolved simply because it was opened.
- Detect changes made outside the conflict editor.
- Do not overwrite newer file content.
- Validate the resulting file.
- Stage only after the user confirms resolution.
- Offer safe abort behavior.
- Provide clear operation status.

Support common text conflicts first.

Handle add/add, modify/delete, binary conflicts, and other special cases through appropriate safe fallback workflows.

---

# 9. Git Operations

## 9.1 Required in V1

Implement the following reliable everyday workflows.

Repository:

- Open local repository.
- Clone repository.
- View repository details.
- Refresh repository status.
- Detect bare and regular repositories.
- Detect linked worktrees where relevant.

Remote:

- Fetch.
- Pull.
- Push.
- Track remote branches.
- Configure upstream.
- Show ahead/behind information.
- Inspect remotes.
- Handle rejected pushes.
- Handle authentication failures.
- Show operation progress.

Prefer fast-forward-only pull by default. Offer explicit alternate integration behavior where appropriate.

Branches:

- Create branch.
- Checkout/switch branch.
- Rename local branch.
- Delete local branch.
- Delete remote branch.
- Create tracking branch.
- Merge branch.
- Basic rebase onto another branch.

Commits:

- Create commit.
- Amend last commit.
- View commit details.
- Compare commits.
- Cherry-pick.
- Revert.
- Copy SHA.
- Copy remote commit link where available.

Files:

- Stage/unstage.
- Partial stage/unstage.
- Discard with confirmation.
- File history.
- Blame.
- Open in editor.

Tags:

- Display existing tags.
- View the tagged commit.

Conflict handling:

- Detect.
- Resolve visually.
- Continue or abort relevant operations.

## 9.2 Preserve for Post-V1 Development

These features were visible in the supplied screenshots or are natural extensions. They must remain in the roadmap and architecture.

- Interactive rebase.
- Drop commit.
- Reorder/move commits.
- Edit older commit messages.
- Reset soft/mixed/hard.
- Worktree creation and management.
- Stash create/apply/pop/drop.
- Reflog explorer and recovery.
- Advanced branch history manipulation.
- Create lightweight tags.
- Create annotated tags.
- Create and apply patches.
- Patch export and sharing through native macOS mechanisms.
- Advanced commit-signing configuration.
- Git LFS management.
- Submodule management.
- Advanced remote management.
- Additional history filtering.

Do not implement an arbitrary hosted Cloud Patch service without a clearly defined backend. Preserve the underlying local patch creation/export capability and a future extension point.

## 9.3 Explicitly Excluded

Do not build:

- GitHub Pull Request creation or management.
- GitLab Merge Request creation or management.
- Code review workflows.
- Provider CI/CD dashboards.
- Provider pipeline management.
- Hosted collaboration services.
- An integrated AI coding assistant.
- A built-in general-purpose IDE.

Provider APIs are only for authentication, repository discovery, metadata needed by the Git client, and obtaining supported clone URLs.

---

# 10. Git Profiles and Account Management

The application has **exactly one globally active Git profile at a time**.

There are no automatically selected per-repository profiles in V1.

A profile combines Git identity and optional authentication/provider configuration, but these concepts must remain distinct internally.

## 10.1 Profile Model

Each profile can contain:

- Profile ID.
- Display name.
- Optional profile icon or color.
- Git author name.
- Git author email.
- Optional Git committer settings.
- Provider type.
- Associated hosting account ID.
- Provider hostname.
- Preferred Git transport.
- SSH identity reference.
- HTTPS credential reference.
- Optional commit signing settings for later.
- Enterprise networking configuration reference.

Support multiple profiles for the same provider.

Examples:

- Personal GitHub.
- Work GitLab Self-Managed.
- Open-source GitHub.
- Client GitLab.com.

## 10.2 Global Profile Selector

Create a beautiful native global profile-switcher menu.

Requirements:

- Clearly show the active profile.
- List all profiles.
- Display provider and identity information.
- Search profiles if needed.
- Switch with one click.
- Add profile.
- Edit profile.
- Remove profile.
- Show authentication status.
- Show disconnected or expired accounts.
- Persist the selection.

Profile selection is manual.

Do not automatically switch based on repository hostname.

When the profile changes:

- All repository tabs reflect the new global profile.
- Future commit operations use the new identity.
- Future remote operations use the selected account/credentials.
- Existing commits remain unchanged.
- Existing in-flight operations retain their original profile snapshot.
- The global .gitconfig is not modified.

When the selected profile cannot authenticate to a repository's remote, explain the mismatch and offer a profile-switch action.

Do not silently fall back to another account.

## 10.3 Git Identity vs Authentication

Model these separately:

**Commit identity**

- Author name.
- Author email.
- Committer name/email when applicable.
- Signing identity where configured.

**Remote authentication**

- Provider account.
- SSH identity.
- PAT or OAuth credentials.
- Remote host and protocol.

Never assume that the Git email identifies the remote account.

Use invocation-scoped Git configuration for selected identity overrides.

Respect repository configuration where compatible without writing permanent modifications unless the user explicitly requests them.

Never modify the global Git configuration as a side effect of switching profiles.

---

# 11. GitHub and GitLab Integration

Support:

1. GitHub.com.
2. GitLab.com.
3. Any compatible GitLab Self-Managed instance.

## 11.1 Provider Accounts

Allow:

- Multiple accounts per provider.
- Multiple self-hosted GitLab servers.
- Separate credentials for the same hostname.
- Disconnect/reconnect.
- Authentication health checks.
- Token expiration handling.
- OAuth refresh where supported.
- Explicit profile/account associations.

## 11.2 Authentication

Support:

### SSH

- Choose an existing SSH key.
- Support SSH agent.
- Support passphrase-protected keys.
- Correctly associate an SSH identity with a profile.
- Respect known_hosts verification.
- Do not automatically accept untrusted SSH host keys.
- Explain SSH authentication failures.
- Support custom self-hosted SSH hostnames and ports.

Use a safe profile-aware SSH invocation mechanism.

Do not rely on mutating global SSH configuration.

### Personal Access Tokens

- Support PAT-based authentication.
- Store tokens in macOS Keychain.
- Never store tokens in plaintext preferences.
- Never embed tokens in remote URLs.
- Never pass tokens through command-line arguments.
- Never print them in logs or error messages.
- Allow credential rotation and removal.
- Detect invalid/revoked tokens.
- Explain missing required permissions without demanding unnecessarily broad scopes.

### Browser-Based OAuth

Use native browser-based authentication.

Prefer authorization code with PKCE, where supported, with proper state validation.

Use Apple's AuthenticationServices APIs where appropriate.

Requirements:

- No embedded web login.
- No hardcoded client secrets in the distributed binary.
- Secure callback handling.
- CSRF protection.
- PKCE verifier/challenge handling.
- Secure token persistence.
- Appropriate token refresh.
- Explicit logout/revoke behavior where supported.
- Graceful handling of rejected or canceled authorization.

OAuth client registration is required.

Use valid registered public-client configurations. Do not invent client IDs or credentials.

For self-hosted GitLab, allow administrators or users to configure the required OAuth application registration information.

Support PAT and SSH as alternatives where OAuth is unavailable or restricted.

Do not claim self-hosted OAuth works until the target instance's version, registration, and configuration have been validated.

## 11.3 Remote Repository Browser

Create a native repository discovery experience.

Allow the user to:

- Select an account/provider.
- Browse accessible repositories.
- Search repositories.
- See name, namespace/owner, visibility, and description.
- Display a repository's clone URLs.
- Choose HTTPS or SSH.
- Select a local clone destination.
- Clone with progress and cancellation.
- Open the repository automatically after cloning.

Use pagination for large account inventories.

Do not fetch every repository at startup.

Do not continuously refresh remote lists in the background.

Use short-lived caches only when useful.

## 11.4 Provider Abstraction

Separate provider-specific functionality.

Create implementations conceptually equivalent to:

- GitHubProvider.
- GitLabProvider.

GitLab.com and GitLab Self-Managed should reuse the GitLab implementation with instance-specific configuration.

Keep provider API functionality separate from local Git operations.

Native Swift networking via URLSession is preferred for provider API integration because of macOS authentication, proxy, and certificate integration.

The Rust core owns Git repository operations, not the full application UI or OAuth presentation.

---

# 12. Enterprise GitLab Networking

Self-hosted GitLab support is mandatory.

## 12.1 Server Configuration

Support:

- Custom HTTPS hostname.
- Custom HTTPS port.
- Custom SSH port.
- Custom server path where supported.
- Server connectivity test.
- Repository API endpoint discovery/validation.
- Multiple server configurations.

## 12.2 Custom Certificates

Support private or enterprise CA certificates.

Requirements:

- Import an approved CA certificate.
- Associate certificates with the intended self-hosted server.
- Validate server identity and hostname.
- Apply trust configuration to provider API calls.
- Apply appropriate CA configuration to Git HTTPS transport.
- Clearly report certificate failures.
- Never silently bypass certificate validation.
- Never enable global insecure TLS settings.
- Never automatically trust unknown certificates.

Handle certificate expiry and rotation gracefully.

## 12.3 Proxy Support

Support:

- macOS system proxy settings.
- HTTP/HTTPS proxies.
- SOCKS proxies where supported.
- Authentication for proxies when required.
- Optional provider/host-specific proxy configuration.
- Proxy connection diagnostics.

Apply relevant proxy settings consistently to both Git operations and provider API requests.

Store proxy credentials securely.

## 12.4 VPN Compatibility

The application does not need to implement a VPN client.

It must:

- Work through the user's existing system VPN.
- Respect macOS routing and proxy behavior.
- Handle DNS or connectivity failures gracefully.
- Retry only when appropriate.
- Display useful diagnostics for unreachable internal hosts.
- Avoid background polling while offline.

Do not assume private GitLab servers are publicly reachable.

---

# 13. Technical Architecture

Use this primary architecture:

**SwiftUI + AppKit → Application Services → UniFFI → Rust Git Core → Git**

Provider authentication and API networking live in dedicated native macOS services.

## 13.1 Swift Layer

Responsibilities:

- Window management.
- Tabs.
- Native navigation.
- Design system.
- Git graph rendering.
- Diff rendering.
- Conflict editor.
- Profile management UI.
- Keychain integration.
- OAuth browser flow.
- Provider API clients.
- Repository browsing.
- Theme management.
- Keyboard shortcuts.
- Accessibility.
- macOS integration.

## 13.2 Rust Core

Responsibilities:

- Repository discovery.
- Git command orchestration.
- Git status parsing.
- History retrieval.
- Commit graph model and lane layout.
- Branch and reference operations.
- Git diff parsing.
- Patch construction.
- Partial staging and unstaging.
- Commit creation.
- Merge/rebase/cherry-pick orchestration.
- Conflict detection.
- Operation lifecycle.
- Typed error handling.
- Cancellation.
- Repository state caching.
- Cache invalidation.
- Git integration tests.

## 13.3 UniFFI Bridge

Use UniFFI to expose typed Rust services to Swift.

The bridge must provide:

- Typed repository IDs.
- Typed operation requests.
- Typed responses.
- Structured errors.
- Pagination.
- Operation progress.
- Cancellation.
- Minimal data copying.
- Controlled ownership and lifetimes.

Do not send entire histories or huge file contents through the bridge.

Use Swift concurrency correctly.

Never block the main thread waiting on Rust or Git operations.

Prefer bounded asynchronous operations instead of unbounded event streams.

## 13.4 Git Backend Strategy

Prefer the installed Git CLI for Git semantics and complex operations.

Use Rust to orchestrate Git processes and parse output efficiently.

Evaluate `gix` only for specific read-intensive bottlenecks if profiling demonstrates a significant benefit.

Avoid bringing in multiple competing Git implementations without justification.

Consider:

- Git compatibility.
- Subprocess overhead.
- Resource consumption.
- Partial staging correctness.
- Authentication.
- Packaging complexity.
- Operational safety.

Make the choice explicit in an architecture decision record.

For distributed builds, the application must not silently depend on Xcode Command Line Tools being installed.

Investigate bundling a vetted, properly signed universal Git executable and required supporting components.

The release must either provide a tested standalone Git runtime or clearly surface an unavoidable prerequisite during onboarding. Prefer the standalone experience.

Do not claim a standalone DMG works until tested on a clean macOS installation.

## 13.5 Git Process Safety

- Launch Git with structured argument arrays.
- Never concatenate untrusted shell commands.
- Treat file paths, branch names, remote URLs, and user input as untrusted.
- Avoid shell interpolation.
- Use argument separators where applicable.
- Set a known repository working directory.
- Validate repository state before writing.
- Restrict credential lookup to the selected profile and intended remote.
- Prefer invocation-scoped Git configuration.
- Use secure credential-helper or askpass mechanisms.
- Never expose tokens through environment variables that might be logged or leaked unnecessarily.
- Avoid terminal prompts that can hang an operation.
- Capture and sanitize process errors.
- Support safe cancellation.

## 13.6 Suggested Project Structure

Use a structure similar to:

```text
/
├── macos/
│   ├── App/
│   ├── DesignSystem/
│   ├── Features/
│   │   ├── RepositoryTabs/
│   │   ├── RepositoryBrowser/
│   │   ├── GitGraph/
│   │   ├── BranchNavigator/
│   │   ├── WorkingDirectory/
│   │   ├── DiffViewer/
│   │   ├── ConflictResolver/
│   │   ├── CommitComposer/
│   │   ├── Profiles/
│   │   └── Settings/
│   ├── Services/
│   │   ├── Authentication/
│   │   ├── GitHub/
│   │   ├── GitLab/
│   │   └── Keychain/
│   └── Resources/
├── rust/
│   ├── crates/
│   │   ├── git-core/
│   │   └── git-ffi/
│   └── Cargo.toml
├── tests/
│   └── fixtures/
├── scripts/
│   ├── build/
│   ├── benchmarks/
│   └── release/
├── docs/
│   ├── product.md
│   ├── architecture.md
│   ├── design-system.md
│   ├── performance.md
│   ├── security.md
│   ├── release.md
│   ├── roadmap.md
│   └── adr/
├── README.md
└── CLAUDE.md
```

Adjust if the existing project requires a different structure.

Do not create directories without a meaningful purpose.

---

# 14. Application State Management

Use simple, explicit state management.

Separate:

- Global application state.
- Global Git profile state.
- Per-repository session state.
- Graph presentation state.
- Diff selection state.
- Git operation state.
- Provider authentication state.
- Persistent UI preferences.

Avoid giant observable objects.

Do not publish entire repository state when only one property changed.

Use targeted view invalidation.

Ensure repository operations are serialized when they mutate the same index or working tree.

Allow safe concurrent read-only operations where appropriate.

Prevent races between:

- External file changes.
- Git operations.
- Profile switching.
- Tab closing.
- Repository refresh.
- Diff staging.
- Conflict resolution.

Use immutable snapshots or revision identifiers to detect stale operations.

---

# 15. Performance Engineering

Performance is a release-blocking requirement.

Do not just claim the application is lightweight because it uses Rust.

Prove it through measurement.

## 15.1 Initial Performance Targets

Treat these as ambitious engineering targets to validate against reference hardware, not unverified promises.

| Metric | Initial target |
|---|---|
| First visible window on warm startup | Under 500 ms |
| First visible window on cold startup | Aim for under 1 second |
| Idle CPU after settling | Aim for 0.0–0.2% of one logical core |
| Background network while idle | None unless explicitly requested |
| Idle memory with no repository loaded | Aim for under 120 MB |
| Memory with a typical active repository | Aim for under 200 MB |
| Graph scrolling | Target 60 FPS |
| Diff switching | Perceived as immediate for normal files |
| Repository tab switching | Immediate cached UI presentation |
| Background polling | None |
| Memory growth while idle | No sustained growth |

Use release builds for performance measurements.

Specify the tested Mac model, macOS version, Git version, repository size, and measurement method.

If targets are not achievable, report measured results and identify the bottleneck instead of falsifying benchmarks.

## 15.2 Startup

At startup:

1. Show the native application window immediately.
2. Load lightweight preferences.
3. Restore tabs visually.
4. Defer Git data loading until required.
5. Load the active repository first.
6. Avoid eagerly initializing every provider.
7. Avoid starting unnecessary workers.
8. Avoid network requests.

Do not scan all configured repositories before showing the window.

## 15.3 Idle Behavior

When the user is not interacting:

- Do not poll repository status.
- Do not periodically fetch remotes.
- Do not refresh avatars.
- Do not run timers without a concrete purpose.
- Do not repeatedly parse Git history.
- Do not animate hidden views.
- Do not perform expensive cache maintenance.
- Do not periodically refresh an inactive tab.
- Do not spin background threads.

Use event-driven notifications for filesystem changes.

Coalesce bursts of changes.

Refresh relevant state when the application becomes active, where necessary.

For minimized and inactive windows, suspend unnecessary rendering and work.

Aim for the application's CPU usage to settle as close to zero as practical.

## 15.4 File Watching

Use native filesystem notifications, such as FSEvents, where appropriate.

Watch relevant repository state efficiently.

Avoid monitoring every file individually.

Debounce event bursts.

Avoid triggering a full repository reload when a single file changes.

## 15.5 Memory

- Keep Git history paginated.
- Avoid retaining full file contents unnecessarily.
- Bound caches.
- Use efficient Rust data structures.
- Avoid unnecessary string duplication.
- Avoid Swift/Rust bridge copies.
- Release inactive diff buffers.
- Release completed operation resources.
- Avoid retaining old graph layouts unnecessarily.
- Test repeated opening and closing of repositories.

## 15.6 Performance Testing

Measure:

- Cold launch.
- Warm launch.
- Idle CPU.
- Idle energy impact.
- Idle wakeups.
- Resident and physical memory.
- Repository open time.
- Branch switching.
- Graph pagination.
- Graph scrolling.
- Diff rendering.
- Large file handling.
- Multiple open repositories.
- Background/inactive behavior.

Use Instruments or suitable macOS profiling tools.

Create repeatable benchmarks.

Document baseline, bottlenecks, and improvements.

---

# 16. Reliability and Safety

Every Git operation must be classified by risk.

## 16.1 Non-Destructive Operations

Examples:

- Fetch.
- History reading.
- Diff reading.
- Branch inspection.
- Blame.
- Remote listing.

These should run with minimal friction.

## 16.2 Mutating Operations

Examples:

- Stage.
- Unstage.
- Commit.
- Checkout.
- Merge.
- Rebase.
- Cherry-pick.

Validate repository state and handle conflicts correctly.

## 16.3 Destructive Operations

Examples:

- Discard.
- Hard reset.
- Drop commit.
- Force push.
- Delete branch.
- Abort with potential work loss.

Require context-aware confirmation.

The UI must explain:

- What will change.
- What might be lost.
- Whether the operation can be recovered.
- Which repository and branch are affected.

Never hide destructive behavior behind ambiguous button labels.

## 16.4 Error Handling

Provide useful errors for:

- Invalid repository.
- Detached HEAD.
- Dirty working directory.
- Unmerged index.
- Invalid credentials.
- Expired token.
- SSH failure.
- TLS failure.
- Proxy failure.
- Remote unreachable.
- Rejected push.
- Merge conflicts.
- Stale diff.
- Locked index.
- Missing Git executable.
- Permission denied.
- Disk full.
- Operation canceled.

Never show only a raw subprocess exit code when a meaningful explanation can be provided.

---

# 17. Keyboard, Accessibility, and macOS Integration

This must feel like native Mac software.

Implement:

- Standard application menu.
- File menu.
- Repository menu.
- Branch menu.
- View menu.
- Git Operations menu.
- Window menu.
- Help menu.
- Native keyboard shortcuts.
- Keyboard navigable lists.
- Native drag-and-drop.
- Open recent.
- Finder integration.
- Open repository in Terminal.
- Open file in external editor.
- Copy SHA/branch/path.
- Contextual right-click menus.
- Native notifications only where useful.

Recommended shortcuts:

- Command+O: Open repository.
- Command+T: New tab.
- Command+W: Close tab.
- Command+F: Search/filter current view.
- Command+K: Command palette.
- Command+Return: Commit, when composer is active.
- Command+1/2/3: Switch main workbench modes, where appropriate.

Avoid overriding standard macOS keyboard behavior unexpectedly.

Accessibility:

- VoiceOver labels.
- Logical focus order.
- Accessible graph navigation.
- Sufficient contrast.
- Keyboard operation.
- Reduce Motion support.
- Dynamic text support where practical.

---

# 18. Testing Strategy

Use real temporary Git repositories.

Do not rely exclusively on mocked Git output.

## 18.1 Rust Unit Tests

Test:

- Git output parsing.
- Status parsing.
- Graph lane assignment.
- Branch relationships.
- Diff parsing.
- Patch generation.
- Patch validation.
- Profile selection semantics.
- Repository state transitions.
- Error mapping.
- Cache invalidation.

## 18.2 Git Integration Tests

Create fixtures covering:

- Empty repository.
- Repository without commits.
- Linear history.
- Multiple branches.
- Merge commits.
- Diverged branches.
- Detached HEAD.
- Renames.
- Binary changes.
- Unicode filenames.
- CRLF files.
- Files without trailing newline.
- Partially staged files.
- Untracked files.
- Conflict resolution.
- Merge abort.
- Rebase conflict.
- Cherry-pick conflict.
- Git index locking.
- External file changes.
- Invalid branch names.
- Authentication failure.
- Rejected push.
- Multiple worktrees.
- Large histories.

For destructive action tests, assert that unrelated data remains unchanged.

## 18.3 Swift UI Tests

Test:

- New-tab experience.
- Opening repositories.
- Tab switching.
- Theme switching.
- Sidebar navigation.
- Commit selection.
- Diff navigation.
- File staging.
- Commit flow.
- Profile switching.
- Authentication state.
- Conflict resolution.
- Keyboard navigation.

## 18.4 Visual Regression

Capture representative native screenshots of:

- Empty state.
- Repository graph.
- Working directory.
- Side-by-side diff.
- Unified diff.
- Conflict resolver.
- Profile switcher.
- Repository browser.
- Settings.

Test both light and dark themes.

Review visual differences after significant UI changes.

## 18.5 Performance Regression

Create benchmark scenarios for:

- 1,000 commits.
- 10,000 commits.
- 100,000+ commits.
- Many branches and merges.
- Hundreds of changed files.
- Large text diffs.
- Multiple open tabs.

Track CPU, memory, loading, and rendering metrics.

---

# 19. Security Requirements

This application operates on source code and potentially sensitive repositories.

Treat it as security-sensitive software.

Requirements:

- macOS Keychain for secrets.
- No plaintext credential storage.
- No tokens in logs.
- No credentials in clone URLs.
- No hardcoded OAuth client secrets.
- Proper OAuth state and PKCE.
- SSH host verification.
- HTTPS certificate verification.
- Scoped custom CA handling.
- Safe process arguments.
- No shell injection.
- Secure temporary files.
- Appropriate file permissions.
- No unintended remote requests.
- No telemetry by default.
- No uploading repository contents.
- No automatic cloud synchronization.
- No remote code execution through untrusted Git metadata.
- Do not execute Git hooks as an undocumented side effect; respect Git behavior and make relevant security implications clear.
- No arbitrary external diff tools or filters without an explicit policy and user awareness.

Audit third-party dependencies.

Prefer actively maintained libraries with clear licenses and limited dependencies.

Do not collect analytics, crash reports, or repository metadata without explicit user consent.

---

# 20. Signed and Notarized Distribution

Produce a release process for a professional macOS application.

Requirements:

- Release build.
- Apple Silicon build.
- Intel build where supported.
- Universal binary packaging.
- Rust library integration.
- Signing of all embedded binaries.
- Developer ID Application signing.
- Hardened Runtime.
- Proper entitlements.
- DMG creation.
- Apple notarization.
- Stapling.
- Gatekeeper verification.
- Clean-machine installation test.

Use Apple's supported `notarytool` workflow.

Provide repeatable scripts for:

1. Building native Swift components.
2. Building Rust components.
3. Producing the required architectures.
4. Packaging native dependencies.
5. Signing embedded code.
6. Signing the application bundle.
7. Creating the DMG.
8. Submitting for notarization.
9. Stapling the ticket.
10. Validating the final DMG.

Ensure release signing credentials are never committed to the repository.

Do not fabricate a successful notarization result.

If a Developer ID certificate or Apple notarization credentials are unavailable, prepare and verify all locally possible steps and clearly report the remaining external prerequisites.

The application must not require the end user to install Rust, Cargo, or Xcode.

---

# 21. Documentation and Engineering Discipline

Maintain concise, accurate documentation.

Required:

- README.
- Local development instructions.
- Product specification.
- Architecture overview.
- Swift/Rust integration explanation.
- Git command execution strategy.
- Authentication and profile model.
- UI design system.
- Performance baseline and results.
- Security considerations.
- Release procedure.
- Roadmap.
- Architecture Decision Records for major decisions.

Follow a lightweight spec-driven development process.

Before implementing a significant feature:

1. Write a concise feature specification.
2. Define observable behavior.
3. Define failure and edge cases.
4. Define tests.
5. Implement.
6. Verify.
7. Update the documentation to match reality.

Documentation must not describe unimplemented behavior as completed functionality.

Avoid generating documentation that adds no useful information.

---

# 22. Implementation Phases

Build in small, functional vertical slices.

Each phase must leave the application in a working, testable state.

## Phase 0 — Foundation and Design

Deliver:

- Technical feasibility review.
- Clear architecture.
- Design direction.
- Design tokens.
- Native app shell.
- Rust workspace.
- UniFFI bridge.
- Build scripts.
- Development documentation.
- Initial performance baseline.

Do not spend the entire phase on documentation.

The phase should end with a working native macOS window successfully invoking Rust code.

## Phase 1 — Native Shell and Repository Tabs

Deliver:

- Premium top tab bar.
- New-tab page.
- Open local repository.
- Recent repositories.
- Theme switching.
- Global profile indicator.
- State persistence.
- Native menus and shortcuts.
- Basic repository status.

Verify startup behavior and idle CPU.

## Phase 2 — Git Graph and Navigation

Deliver:

- Commit history.
- Graph lane algorithm.
- Native graph renderer.
- Branch navigator.
- Tags.
- Commit details.
- Selection.
- Graph context menus.
- Search and filtering.
- Incremental history loading.
- Basic graph comparisons.

This phase must receive significant design and performance attention.

Do not accept a visually mediocre graph as finished.

## Phase 3 — Working Directory and Diff Viewer

Deliver:

- Staged/unstaged files.
- File tree/path modes.
- Native diff viewer.
- Unified and side-by-side views.
- Syntax highlighting.
- File-level stage/unstage.
- Hunk-level stage/unstage.
- Line-level stage/unstage.
- Safe discard.
- Commit composer.
- Commit and amend operations.

This is a flagship phase.

Write extensive integration tests for partial staging.

## Phase 4 — Everyday Git Workflows and Conflicts

Deliver:

- Fetch/pull/push.
- Branch operations.
- Merge.
- Basic rebase.
- Cherry-pick.
- Revert.
- Conflict detection.
- Native visual conflict resolver.
- Continue/abort flows.
- Error recovery.

Ensure correct behavior with dirty working trees and unresolved conflicts.

## Phase 5 — Profiles and Providers

Deliver:

- Global Git profile manager.
- SSH authentication.
- PAT authentication.
- Browser-based OAuth.
- Keychain integration.
- GitHub repository browsing.
- GitLab.com repository browsing.
- Self-hosted GitLab browsing.
- CA certificate support.
- Proxy support.
- Existing-VPN compatibility.
- Repository clone workflows.
- Credential/profile mismatch handling.

Do not silently change the user's selected profile.

## Phase 6 — Polish and Performance

Deliver:

- High-quality interactions.
- Light/dark refinement.
- Keyboard workflows.
- Accessibility.
- Performance profiling.
- Startup optimization.
- Memory optimization.
- Idle CPU optimization.
- Large repository testing.
- Visual regression checks.

Profile before optimizing.

## Phase 7 — Packaging and Release

Deliver:

- Production build.
- Signed application bundle.
- Notarization workflow.
- DMG packaging.
- Clean-machine verification.
- Release checklist.
- Final documentation.
- Measured performance report.

If external signing credentials are unavailable, report the release as blocked on those credentials rather than falsely completed.

## Phase 8 — Post-V1 Roadmap

Preserve and later implement:

- Interactive rebase.
- Advanced commit editing.
- Commit dropping/reordering.
- Reset modes.
- Stash manager.
- Worktree manager.
- Reflog recovery.
- Advanced tag and patch workflows.
- Git LFS and submodules.
- Additional power-user functionality.

Do not let these features delay the first production-quality daily-workflow release.

---

# 23. Definition of Done

A feature is complete only when:

1. It works with real Git repositories.
2. Its UI matches the approved design system.
3. Its loading/error/empty states are implemented.
4. It works in light and dark themes.
5. It has appropriate tests.
6. It does not block the main thread.
7. It avoids unnecessary resource usage.
8. It handles cancellation and failure safely.
9. It does not silently destroy user data.
10. Its documentation matches the implementation.

A completed phase must be demonstrable.

Do not substitute mock data, placeholder buttons, or fake operation success for working functionality.

If a feature is not implemented, label it as planned rather than pretending it works.

---

# 24. Final V1 Acceptance Scenarios

Before declaring V1 ready, verify these end-to-end scenarios.

### Scenario A — Clean Launch

Install and launch the application.

Expected:

- Window appears quickly.
- UI looks premium.
- No unnecessary background network requests.
- Near-zero CPU after the application becomes idle.
- Stable memory usage.
- Light/dark themes work correctly.

### Scenario B — Repository Graph

Open a real repository with multiple branches and merges.

Expected:

- Graph renders correctly.
- Branch lanes remain stable.
- Commit selection is responsive.
- History loads incrementally.
- Scrolling remains smooth.
- Tags and references are accurate.

### Scenario C — Partial Staging

Modify several lines in a file.

Expected:

- Diff shows the changes correctly.
- Stage one selected line.
- Other lines remain unstaged.
- Unstage the selected line.
- Discard another selected line.
- Unrelated changes are preserved.

### Scenario D — Conflict Resolution

Create a real merge conflict.

Expected:

- Conflict is detected.
- Three-way editor opens.
- User can select or manually combine changes.
- Result is saved safely.
- Conflict is marked resolved only when appropriate.
- Git operation can continue successfully.

### Scenario E — Multiple Profiles

Configure two GitHub accounts and one self-hosted GitLab account.

Expected:

- All accounts coexist.
- Switch the global profile manually.
- All tabs show the active profile.
- Commit identity follows the selected profile.
- Remote credentials follow the selected profile.
- No global Git configuration changes.
- Wrong-account operations do not silently succeed under another account.

### Scenario F — Enterprise GitLab

Configure a private GitLab server using a custom CA and network proxy.

Expected:

- Correct TLS validation.
- Repository browsing works.
- HTTPS Git operations use appropriate trust/proxy configuration.
- SSH works when configured.
- Unreachable hosts produce useful diagnostics.

### Scenario G — Real Distribution

Install the DMG on a clean macOS machine.

Expected:

- Correct signing and notarization.
- No development toolchain dependency.
- Application launches normally.
- Repository operations work.
- Required helper binaries are included or prerequisites are clearly handled.

---

# 25. Instructions for How You Must Work

You are implementing this application, not merely advising on it.

Follow this process.

**Step 1: Inspect the environment.**

Determine:

- Existing project files.
- macOS and Xcode versions.
- Available Swift version.
- Rust toolchain.
- Git availability.
- Build architectures.
- Available signing configuration.
- Relevant dependencies.

Do not overwrite existing code without inspecting it.

**Step 2: Establish an implementation plan.**

Create a concise, dependency-aware implementation plan that maps to the phases above.

Identify major technical risks.

Choose the simplest viable architecture.

Record major decisions.

**Step 3: Begin implementing immediately.**

Do not stop after producing documentation or the plan.

Create the native application shell, Rust core, and functional bridge.

Then proceed through the planned vertical slices.

**Step 4: Verify every slice.**

After a feature is implemented:

- Compile it.
- Run relevant tests.
- Exercise the real workflow where the environment allows.
- Inspect UI output when possible.
- Fix correctness issues.
- Measure relevant performance.
- Update the plan.

Do not silently skip failing tests.

**Step 5: Review your own changes.**

Act as a strict senior reviewer.

Look for:

- Incorrect Git behavior.
- Data-loss risks.
- Race conditions.
- Memory leaks.
- UI-thread blocking.
- Unbounded caches.
- Background CPU waste.
- Inefficient rendering.
- Security problems.
- Duplicated logic.
- Over-engineering.
- Broken native conventions.
- Poor UX and visual inconsistency.
- Outdated documentation.

Prioritize genuine blockers over cosmetic code-style nitpicks.

**Step 6: Maintain progress visibility.**

At the end of each implementation phase, report:

- What was implemented.
- What was verified.
- Tests passed.
- Performance measurements.
- Important unresolved issues.
- Next phase.

Do not claim a feature is complete without verification.

Do not fabricate benchmark results or successful releases.

---

# 26. Final Engineering Priorities

When making tradeoffs, use this priority order:

1. Protect the user's repositories and data.
2. Correct Git behavior.
3. Excellent user experience.
4. UI responsiveness.
5. Low idle resource consumption.
6. Low overall memory consumption.
7. Fast startup.
8. Maintainable, simple code.
9. Advanced power-user functionality.

Do not choose a visually ugly approach simply because it is easier.

Do not choose a visually impressive approach that causes constant CPU usage or poor scrolling.

Do not over-engineer features that can be implemented simply.

Prefer measured engineering decisions.

---

# 27. Start Now

Start with the environment inspection and Phase 0.

Create the initial architecture and feature plan, establish the project, and implement the first working SwiftUI/AppKit window communicating with the Rust core.

Then proceed toward the initial repository tabs and Git graph.

The goal is not to produce an impressive plan.

**The goal is to ship an exceptionally beautiful, fast, reliable native macOS Git client that I will genuinely want to use every day.**
