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
            inspectorWidth: record.map { Self.upgradedInspector(CGFloat($0.inspectorWidth)) }
                ?? PanelMetrics.inspectorDefault)
    }

    /// The inspector's default grew from 360 to 420 pt in 0.0.3: a width still at the old default follows it
    /// (a width the user chose stays).
    static func upgradedInspector(_ width: CGFloat) -> CGFloat {
        abs(width - 360) < 0.5 ? PanelMetrics.inspectorDefault : width
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
