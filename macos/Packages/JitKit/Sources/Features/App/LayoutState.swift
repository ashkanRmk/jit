import DesignSystem
import Foundation
import Observation
import Services

/// Sidebar and inspector widths, shared by every tab (fewer surprises than per-tab widths). Collapse
/// flags are per tab (`TabModel`).
@MainActor @Observable
public final class LayoutState {
    public var sidebarWidth: CGFloat {
        didSet { if sidebarWidth != Self.clampSidebar(sidebarWidth) { sidebarWidth = Self.clampSidebar(sidebarWidth) } }
    }

    public var inspectorWidth: CGFloat {
        didSet {
            if inspectorWidth != Self.clampInspector(inspectorWidth) {
                inspectorWidth = Self.clampInspector(inspectorWidth)
            }
        }
    }

    public init(
        sidebarWidth: CGFloat = PanelMetrics.sidebarDefault, inspectorWidth: CGFloat = PanelMetrics.inspectorDefault
    ) {
        self.sidebarWidth = Self.clampSidebar(sidebarWidth)
        self.inspectorWidth = Self.clampInspector(inspectorWidth)
    }

    public convenience init(_ record: SessionState.Layout?) {
        self.init(
            sidebarWidth: record.map { CGFloat($0.sidebarWidth) } ?? PanelMetrics.sidebarDefault,
            inspectorWidth: record.map { CGFloat($0.inspectorWidth) } ?? PanelMetrics.inspectorDefault)
    }

    public var record: SessionState.Layout {
        SessionState.Layout(sidebarWidth: Double(sidebarWidth), inspectorWidth: Double(inspectorWidth))
    }

    public static func clampSidebar(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return PanelMetrics.sidebarDefault }
        return min(PanelMetrics.sidebarMax, max(PanelMetrics.sidebarMin, width))
    }

    public static func clampInspector(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return PanelMetrics.inspectorDefault }
        return min(PanelMetrics.inspectorMax, max(PanelMetrics.inspectorMin, width))
    }
}
