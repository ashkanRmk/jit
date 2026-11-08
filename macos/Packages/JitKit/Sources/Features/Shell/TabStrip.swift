import AppKit
import DesignSystem
import Services
import SwiftUI

/// The tab strip (design §3.1): glass capsule tabs inside one glass container, hosted in an unbordered
/// toolbar item. Observes the tab list and selection only; each `TabItemView` observes its own tab.
struct TabStripView: View {
    let model: AppModel
    @Namespace private var glassNamespace
    @State private var drag: DragState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct DragState: Equatable {
        let id: UUID
        let source: Int
        var translation: CGFloat
        var destination: Int
    }

    var body: some View {
        GeometryReader { geometry in
            let tabs = model.tabs
            let available = max(0, geometry.size.width - TabMetrics.newTabButton - TabMetrics.spacing * 2)
            let layout = TabOrdering.layout(count: tabs.count, available: available)
            HStack(spacing: TabMetrics.spacing) {
                if layout.overflows {
                    // The glass container lives inside the scrolling content so glass is clipped with it.
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            GlassTabStrip { row(tabs, layout: layout) }
                        }
                        .scrollIndicators(.never)
                        .scrollEdgeEffectStyle(.soft, for: .horizontal)
                        .frame(width: available)
                        .clipped()
                        .onChange(of: model.activeTabID) { _, id in
                            guard let id else { return }
                            withAnimation(reduceMotion ? nil : MotionToken.select.animation) {
                                proxy.scrollTo(id)
                            }
                        }
                        .onAppear { model.activeTabID.map { proxy.scrollTo($0) } }
                    }
                } else {
                    GlassTabStrip { row(tabs, layout: layout) }
                }
                GlassTabStrip { NewTabButton { model.newTab() } }
                // Empty toolbar space keeps dragging the window and zooming on double-click.
                WindowDragArea()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
        }
    }

    private func row(_ tabs: [TabModel], layout: TabOrdering.Layout) -> some View {
        HStack(spacing: TabMetrics.spacing) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                TabItemView(
                    tab: tab, index: index, count: tabs.count, isSelected: tab.id == model.activeTabID,
                    width: layout.tabWidth, namespace: glassNamespace,
                    select: { model.select(tab.id) },
                    close: { model.closeTab(tab.id) },
                    move: { offset in model.moveTab(tab.id, by: offset) }
                )
                .id(tab.id)
                .offset(x: offset(for: index, tab: tab, layout: layout))
                .zIndex(drag?.id == tab.id ? 1 : 0)
                // A plain (not high-priority) gesture so the close button inside keeps its clicks.
                .gesture(dragGesture(for: tab, index: index, count: tabs.count, layout: layout))
            }
        }
        .animation(reduceMotion ? nil : MotionToken.select.animation, value: drag?.destination)
        .animation(
            reduceMotion ? .linear(duration: MotionToken.select.duration) : MotionToken.glassMorph.animation,
            value: model.activeTabID)
    }

    private func offset(for index: Int, tab: TabModel, layout: TabOrdering.Layout) -> CGFloat {
        guard let drag else { return 0 }
        if drag.id == tab.id { return drag.translation }
        return TabOrdering.neighborOffset(
            for: index, source: drag.source, destination: drag.destination, tabWidth: layout.tabWidth,
            spacing: TabMetrics.spacing)
    }

    /// Selects on mouse down; reorders once the pointer moves more than a few points. Local tracking
    /// (no pasteboard) keeps the drag smooth; nothing animates after the drop completes.
    private func dragGesture(for tab: TabModel, index: Int, count: Int, layout: TabOrdering.Layout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if model.activeTabID != tab.id { model.select(tab.id) }
                let dx = value.translation.width
                guard drag != nil || abs(dx) > 4, count > 1 else { return }
                let destination = TabOrdering.dropIndex(
                    for: index, translation: dx, tabWidth: layout.tabWidth, spacing: TabMetrics.spacing, count: count)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if drag == nil {
                        drag = DragState(id: tab.id, source: index, translation: dx, destination: destination)
                    } else {
                        drag?.translation = dx
                    }
                }
                if drag?.destination != destination { drag?.destination = destination }
            }
            .onEnded { _ in
                guard let finished = drag else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    drag = nil
                    if finished.destination != finished.source { model.moveTab(finished.id, to: finished.destination) }
                }
            }
    }
}

struct TabItemView: View {
    let tab: TabModel
    let index: Int
    let count: Int
    let isSelected: Bool
    let width: CGFloat
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    let move: (Int) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Space.s3) {
            StatusDotView(dot: tab.statusDot)
            Text(tab.title)
                .font(.body)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            CloseTabButton(title: tab.title, isVisible: isHovered || isSelected, action: close)
        }
        .padding(.leading, TabMetrics.horizontalPadding + Space.s1)
        .padding(.trailing, Space.s3)
        .frame(width: width, height: TabMetrics.height)
        .contentShape(Capsule())
        .glassTab(isSelected: isSelected, isHovered: isHovered, id: tab.id, in: namespace)
        .onHover { isHovered = $0 }
        .help(tab.tooltip)
        .overlay(MiddleClickCatcher(action: close))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title), \(tab.statusDot.description), tab \(index + 1) of \(count)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Close Tab") { close() }
        .accessibilityAction(named: "Move Left") { move(-1) }
        .accessibilityAction(named: "Move Right") { move(1) }
    }
}

private struct CloseTabButton: View {
    let title: String
    let isVisible: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .symbolSize(IconSize.sm - 3, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: TabMetrics.closeButton, height: TabMetrics.closeButton)
                .background(isHovered ? ColorToken.statePressed.color : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .onHover { isHovered = $0 }
        .help("Close Tab (⌘W)")
        .accessibilityLabel("Close \(title)")
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @Namespace private var namespace

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .symbolSize(IconSize.sm, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: TabMetrics.newTabButton, height: TabMetrics.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassTab(isSelected: false, isHovered: isHovered, id: "new-tab", in: namespace)
        .onHover { isHovered = $0 }
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
    }
}

/// The tab's status dot: none = clean, hollow = not loaded, accent = changes, warning = operation in
/// progress, danger = conflicts or error. The label carries the meaning for VoiceOver and tooltips.
struct StatusDotView: View {
    let dot: StatusDot

    var body: some View {
        Group {
            switch dot {
            case .clean:
                Color.clear
            case .notLoaded:
                Circle().strokeBorder(ColorToken.textTertiary.color, lineWidth: Border.emphasis)
            case .changes, .operation, .danger:
                Circle().fill(dot.color)
            }
        }
        .frame(width: TabMetrics.statusDot, height: TabMetrics.statusDot)
        .accessibilityHidden(true)
    }
}

extension StatusDot {
    @MainActor var color: Color { Color(nsColor: nsColor) }

    @MainActor var nsColor: NSColor {
        switch self {
        case .clean: .clear
        case .notLoaded: ColorToken.textTertiary.nsColor
        case .changes: ColorToken.accentBase.nsColor
        case .operation: ColorToken.statusWarning.nsColor
        case .danger: ColorToken.statusDanger.nsColor
        }
    }
}

/// Menu images for the overflow menu and Window menu.
@MainActor
enum StatusDotImage {
    static func image(for dot: StatusDot) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let color = dot.nsColor
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            if dot == .notLoaded {
                color.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            } else {
                color.setFill()
                circle.fill()
            }
            return true
        }
        image.accessibilityDescription = dot.description
        return image
    }
}

/// Catches middle-button clicks over a tab and lets every other event through to SwiftUI.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged: super.hitTest(point)
            default: nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {}

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            action?()
        }
    }
}

/// Empty toolbar space: drags the window, and double-click follows the system title-bar setting.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { TitleBarDoubleClick.perform() })
            .accessibilityHidden(true)
    }
}

@MainActor
enum TitleBarDoubleClick {
    /// Honors System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to".
    static func perform() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
