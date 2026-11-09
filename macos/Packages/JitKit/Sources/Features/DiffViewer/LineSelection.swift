import AppKit
import GitCore

/// Which changed lines are selected for a line action (design §3.3 line selection model). Only `+`/`-`
/// lines are selectable; context lines are skipped. Pure value type.
public struct LineSelection: Equatable, Sendable {
    public private(set) var lines: Set<Int> = []
    /// Start of a ⇧-click / drag range, and the keyboard cursor.
    public private(set) var anchor: Int?
    public private(set) var cursor: Int?

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }
    public var count: Int { lines.count }

    public mutating func clear() {
        lines = []
        anchor = nil
        cursor = nil
    }

    /// Click (plain: select only this; ⌘: toggle; ⇧: range from the anchor) on `line` of `changed` (the
    /// file's changed lines in display order). Clicking a context line clears the selection.
    public mutating func click(_ line: Int, changed: [Int], modifiers: NSEvent.ModifierFlags) {
        guard changed.contains(line) else {
            if !modifiers.contains(.command) && !modifiers.contains(.shift) { clear() }
            return
        }
        if modifiers.contains(.shift), let anchor {
            lines = range(anchor, line, in: changed)
        } else if modifiers.contains(.command) {
            if lines.contains(line) { lines.remove(line) } else { lines.insert(line) }
            anchor = line
        } else {
            lines = [line]
            anchor = line
        }
        cursor = line
    }

    /// Drag from the anchor to `line`.
    public mutating func drag(to line: Int, changed: [Int]) {
        guard let anchor else { return click(line, changed: changed, modifiers: []) }
        let target = changed.contains(line) ? line : nearest(line, in: changed) ?? anchor
        lines = range(anchor, target, in: changed)
        cursor = target
    }

    /// Clicking a hunk header: selects its changed lines, or clears them if all were selected.
    public mutating func toggleHunk(_ hunkLines: [Int]) {
        guard !hunkLines.isEmpty else { return }
        if Set(hunkLines).isSubset(of: lines) {
            lines.subtract(hunkLines)
        } else {
            lines = Set(hunkLines)
        }
        anchor = hunkLines.first
        cursor = hunkLines.last
    }

    /// ↑/↓ moves to the previous/next changed line (⇧ extends from the anchor).
    public mutating func move(forward: Bool, extend: Bool, changed: [Int]) {
        guard !changed.isEmpty else { return }
        let next: Int
        if let cursor, let index = changed.firstIndex(of: cursor) {
            next = changed[max(0, min(changed.count - 1, index + (forward ? 1 : -1)))]
        } else {
            next = forward ? changed[0] : changed[changed.count - 1]
        }
        if extend, let anchor {
            lines = range(anchor, next, in: changed)
        } else {
            lines = [next]
            anchor = next
        }
        cursor = next
    }

    /// Space: toggles the cursor line.
    public mutating func toggleCursor() {
        guard let cursor else { return }
        if lines.contains(cursor) { lines.remove(cursor) } else { lines.insert(cursor) }
    }

    /// Keeps only lines that still exist (after a reload with the same bytes).
    public mutating func restrict(to changed: Set<Int>) {
        lines.formIntersection(changed)
        if let anchor, !changed.contains(anchor) { self.anchor = nil }
        if let cursor, !changed.contains(cursor) { self.cursor = nil }
    }

    private func range(_ a: Int, _ b: Int, in changed: [Int]) -> Set<Int> {
        guard let i = changed.firstIndex(of: a), let j = changed.firstIndex(of: b) else { return [b] }
        return Set(changed[min(i, j)...max(i, j)])
    }

    private func nearest(_ line: Int, in changed: [Int]) -> Int? {
        changed.min { abs($0 - line) < abs($1 - line) }
    }
}

/// Which line actions a diff offers and why one is disabled (design §3.3 action table).
public struct LineActionState: Equatable, Sendable {
    public let action: SelectionAction
    public let title: String
    public let isEnabled: Bool
    /// Shown as the help tag when disabled.
    public let reason: String?
    public let isDestructive: Bool
}

public enum LineActions {
    public static func states(
        document: DiffDocument?, target: DiffTarget?, selectionCount: Int, isBusy: Bool
    ) -> [LineActionState] {
        guard let document, let target else { return [] }
        let actions: [SelectionAction]
        switch target {
        case .unstaged: actions = [.stage, .discard, .keepOnly]
        case .staged: actions = [.unstage]
        default: return []
        }
        let unsupported = PatchBuilder.unsupported(document)
        let lines = selectionCount == 1 ? "Line" : "\(selectionCount) Lines"
        return actions.map { action in
            let title: String
            switch action {
            case .stage: title = "Stage \(lines)"
            case .unstage: title = "Unstage \(lines)"
            case .discard: title = "Discard \(lines)…"
            case .keepOnly: title = "Keep Only Selected…"
            }
            var reason: String?
            if let unsupported {
                reason = unsupported.explanation
            } else if document.token == nil {
                reason = UnsupportedReason.wrongSource.explanation
            } else if selectionCount == 0 {
                reason = UnsupportedReason.noSelection.explanation
            } else if isBusy {
                reason = "Waiting for the previous change to finish."
            }
            return LineActionState(
                action: action, title: title, isEnabled: reason == nil, reason: reason,
                isDestructive: action == .discard || action == .keepOnly)
        }
    }
}
