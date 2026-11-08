import DesignSystem
import Foundation
import GitCore
import Observation
import Services

/// One tab. The tab bar observes only these fields (title, branch, status dot), so a status change in
/// one repository invalidates only that tab's view.
@MainActor @Observable
public final class TabModel: Identifiable {
    public enum Kind: Equatable, Sendable {
        case newTab
        /// Standardized absolute path of the working tree (or git directory of a bare repository).
        case repository(path: String)
    }

    public let id: UUID
    public let kind: Kind
    public internal(set) var title: String
    public internal(set) var branch: String?
    public internal(set) var statusDot: StatusDot

    /// Per-tab layout and feature state (persisted, not observed).
    @ObservationIgnored public var sidebarCollapsed: Bool
    @ObservationIgnored public var inspectorCollapsed: Bool
    @ObservationIgnored public var ui: [String: JSONValue]
    @ObservationIgnored public let session: RepositorySession?

    init(
        id: UUID = UUID(), kind: Kind, title: String, branch: String? = nil, session: RepositorySession? = nil,
        sidebarCollapsed: Bool = false, inspectorCollapsed: Bool = false, ui: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.branch = branch
        self.session = session
        self.sidebarCollapsed = sidebarCollapsed
        self.inspectorCollapsed = inspectorCollapsed
        self.ui = ui
        statusDot = session == nil ? .clean : .notLoaded
    }

    public static let newTabTitle = "New Tab"

    public var path: String? {
        if case .repository(let path) = kind { return path }
        return nil
    }

    public var isRepository: Bool { path != nil }

    /// Tooltip: full path and branch.
    public var tooltip: String {
        guard let path else { return title }
        return [path, branch].compactMap { $0 }.joined(separator: "\n")
    }

    var record: SessionState.Tab {
        SessionState.Tab(
            id: id, kind: isRepository ? .repository : .newTab, path: path, titleCache: title, branchCache: branch,
            sidebarCollapsed: sidebarCollapsed, inspectorCollapsed: inspectorCollapsed, ui: ui)
    }
}

/// Human-readable HEAD for headers, subtitles and tooltips.
public enum BranchLabel {
    public static func text(for branch: BranchHeader) -> String {
        if let head = branch.head { return head }
        guard let oid = branch.oid, !oid.isEmpty else { return "Detached HEAD" }
        return "Detached at \(oid.prefix(7))"
    }

    /// `"main"`, `"main ↑2 ↓1"`, `"No commits yet"`.
    public static func subtitle(for status: RepositoryStatus) -> String {
        var text = status.branch.isUnborn ? "\(status.branch.head ?? "") · No commits yet" : text(for: status.branch)
        if let ahead = status.branch.ahead, let behind = status.branch.behind, ahead + behind > 0 {
            text += "  ↑\(ahead) ↓\(behind)"
        }
        return text
    }
}

/// Pure tab-strip arithmetic (unit-tested in `TabOrderingTests`).
public enum TabOrdering {
    /// The tab to activate after closing the tab at `index` of `count`: the one to its right, else left.
    public static func indexToActivate(afterClosing index: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        return index < count - 1 ? index : index - 1
    }

    /// Moves an element and returns the new array.
    public static func move<T>(_ items: [T], from source: Int, to destination: Int) -> [T] {
        guard items.indices.contains(source) else { return items }
        var result = items
        let item = result.remove(at: source)
        result.insert(item, at: max(0, min(destination, result.count)))
        return result
    }

    /// Wrapping neighbor for keyboard cycling.
    public static func cycle(_ index: Int, by offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + offset) % count + count) % count
    }

    public struct Layout: Equatable, Sendable {
        /// Width of every tab (tabs share the space equally between min and max width).
        public let tabWidth: CGFloat
        /// More tabs than fit at minimum width: the strip scrolls and the overflow menu lists all tabs.
        public let overflows: Bool
        /// Total width of the tab row (without the new-tab button).
        public let contentWidth: CGFloat
    }

    /// Tabs compress from `maxWidth` down to `minWidth`; beyond that the strip scrolls.
    public static func layout(
        count: Int, available: CGFloat, minWidth: CGFloat = TabMetrics.minWidth,
        maxWidth: CGFloat = TabMetrics.maxWidth, spacing: CGFloat = TabMetrics.spacing
    ) -> Layout {
        guard count > 0 else { return Layout(tabWidth: maxWidth, overflows: false, contentWidth: 0) }
        let spacingTotal = spacing * CGFloat(count - 1)
        let fitted = ((available - spacingTotal) / CGFloat(count)).rounded(.down)
        let width = min(maxWidth, max(minWidth, fitted))
        let content = width * CGFloat(count) + spacingTotal
        return Layout(tabWidth: width, overflows: fitted < minWidth, contentWidth: content)
    }

    /// Destination index while dragging tab `index` by `translation` points.
    public static func dropIndex(for index: Int, translation: CGFloat, tabWidth: CGFloat, spacing: CGFloat, count: Int)
        -> Int
    {
        let step = tabWidth + spacing
        guard step > 0, count > 0 else { return index }
        let shift = Int((translation / step).rounded())
        return max(0, min(count - 1, index + shift))
    }

    /// Visual offset of a non-dragged tab while another tab is dragged from `source` toward `destination`.
    public static func neighborOffset(
        for index: Int, source: Int, destination: Int, tabWidth: CGFloat, spacing: CGFloat
    ) -> CGFloat {
        let step = tabWidth + spacing
        if source < destination, index > source, index <= destination { return -step }
        if source > destination, index >= destination, index < source { return step }
        return 0
    }
}
