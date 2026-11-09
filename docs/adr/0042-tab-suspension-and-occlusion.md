# ADR-0042: Tab suspension and occlusion policy

- Status: accepted (confirms and extends the Phase 1 behaviour; amends nothing in ADR-0008)
- Date: 2026-11-09
- Phase: P6
- Requirements: §15.3, §15.4; design §4.4

## Context
Idle must be ≈ 0 with 0, 1 and 5 tabs and with the window visible, minimized or covered, and hidden tabs
must reconcile external edits. Phase 1 already ran only the visible tab of a foreground window. Phase 6
measured it and found the remaining idle work and two defects: closed tabs never deallocated (retain cycles
through hosted SwiftUI views and cross-model closures: +7.6 MB per open/close), and every tab switch
re-applied split-view divider positions.

## Decision
- **Foreground** = app active ∧ window visible ∧ not miniaturized ∧ occlusion state visible. Only the active
  tab of a foreground window has an FSEvents stream, refresh tasks and a history reader. Everything else stops
  watching (`deactivate`) and cancels in-flight reads (their Git processes are killed).
- **Reactivation** revalidates once: status, refs and stashes are refreshed (`scheduleRefresh(all)`), the
  history reader restarts on demand. No polling, no timers.
- **Memory pressure** (`DispatchSource` memory-pressure source): rebuildable caches are trimmed
  (ADR-0043) and inactive sessions are suspended (caches released, view controller dropped); a suspended tab
  rebuilds on activation. In-flight operations hold their own snapshots and are never trimmed.
- **Closing / suspending a tab** tears down the hosted SwiftUI views that capture their controller
  (`WorkbenchController.tearDown`), and cross-model closures capture weakly. `ClosedTabDeallocatesTests` and
  `leaks` (0 leaks after 50 cycles) guard it.
- Divider positions are restored once, and later only when a divider is actually off.
- The accounts service (Keychain, `NWPathMonitor`) is created on first use, never at launch.

## Consequences
- Measured idle (powermetrics, release): 0.01–0.03 ms/s CPU, ≈ 0.1 wakeups/s, 0 GPU, 0 network with 0, 1
  or 5 tabs; open/close loop settles at 66 MB (was 411 MB).
- A hidden tab can show stale data for one refresh after activation (cheap status first, then history).
