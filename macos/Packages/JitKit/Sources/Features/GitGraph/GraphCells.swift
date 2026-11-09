import AppKit
import DesignSystem
import GitCore

/// Shared, per-appearance drawing state for every graph cell (resolved once, not per draw).
@MainActor final class GraphStyle {
    var metrics: GraphMetrics
    let colors = GraphColorTable()
    private(set) var subjectFont = GraphTypography.subject
    private(set) var subjectBoldFont = GraphTypography.subjectEmphasized
    private(set) var pillFont = GraphTypography.pill
    private(set) var pillBoldFont = GraphTypography.pillEmphasized
    private(set) var secondaryFont = GraphTypography.secondary
    private(set) var monoFont = GraphTypography.mono
    private(set) var avatarFont = GraphTypography.avatar
    /// Draw rows translucent (filter "highlight" mode: rows that don't match).
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(density: Density) {
        metrics = .forDensity(density)
    }

    func update(appearance: NSAppearance) -> Bool { colors.update(for: appearance) }
}

/// What a graph cell draws for one row.
enum GraphCellContent {
    case commit(CommitRow, isHead: Bool, wipAbove: Bool, dimmed: Bool)
    /// The working-directory row: dashed node on HEAD's lane, dashed edge down into HEAD's row.
    case wip(lane: Int, color: UInt8)
    /// "Show only matches": topology is meaningless, a plain dot.
    case flat(isMerge: Bool)
    case empty
}

/// Draws one row's lanes and node with Core Graphics (design §3.2). Fully determined by its row, so rows
/// are reusable and drawable in isolation. Decorative for accessibility (the row carries the label).
final class GraphCellView: NSView {
    var style: GraphStyle?
    var content: GraphCellContent = .empty {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let started = GraphBenchmark.drawSamples == nil ? nil : ContinuousClock.now
        defer {
            if let started { GraphBenchmark.drawSamples?.append(GraphBenchmark.ms(ContinuousClock.now - started)) }
        }
        guard let style, let context = NSGraphicsContext.current?.cgContext else { return }
        let metrics = style.metrics
        let colors = style.colors
        let height = bounds.height
        let mid = (height / 2).rounded()
        let scale = window?.backingScaleFactor ?? 2
        context.setLineCap(.butt)
        context.setLineWidth(metrics.edgeWidth)

        func x(_ lane: Int) -> CGFloat {
            GraphMetrics.snap(metrics.laneX(lane), width: metrics.edgeWidth, scale: scale)
        }
        func alpha(_ lane: Int) -> CGFloat { lane >= metrics.maxVisibleLanes ? 0.5 : 1 }

        switch content {
        case .empty:
            return
        case .flat(let isMerge):
            let center = CGPoint(x: x(0), y: mid)
            drawNode(context, at: center, color: colors.lane(0), merge: isMerge, head: false, style: style)
        case .wip(let lane, let color):
            let cx = x(lane)
            context.setStrokeColor(colors.lane(color))
            context.setLineDash(phase: 0, lengths: [2, 2])
            context.move(to: CGPoint(x: cx, y: mid))
            context.addLine(to: CGPoint(x: cx, y: height))
            context.strokePath()
            let radius = metrics.nodeRadius + 0.5
            context.setFillColor(colors.canvas)
            context.fillEllipse(in: CGRect(x: cx - radius, y: mid - radius, width: radius * 2, height: radius * 2))
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: cx - radius, y: mid - radius, width: radius * 2, height: radius * 2))
            context.setLineDash(phase: 0, lengths: [])
        case .commit(let row, let isHead, let wipAbove, let dimmed):
            if dimmed { context.setAlpha(0.45) }
            for segment in row.segments {
                let from = Int(segment.fromLane)
                let to = Int(segment.toLane)
                context.setStrokeColor(
                    colors.lane(segment.color).copy(alpha: alpha(max(from, to))) ?? colors.lane(segment.color))
                let x0 = x(from)
                let x1 = x(to)
                let (y0, y1): (CGFloat, CGFloat)
                switch segment.half {
                case .full: (y0, y1) = (0, height)
                case .top: (y0, y1) = (0, mid)
                case .bottom: (y0, y1) = (mid, height)
                }
                context.move(to: CGPoint(x: x0, y: y0))
                if x0 == x1 {
                    context.addLine(to: CGPoint(x: x1, y: y1))
                } else {
                    // An S-curve kept inside this half row (control points at 50 % of its height).
                    let control = y0 + (y1 - y0) / 2
                    context.addCurve(
                        to: CGPoint(x: x1, y: y1), control1: CGPoint(x: x0, y: control),
                        control2: CGPoint(x: x1, y: control))
                }
                context.strokePath()
            }
            let lane = Int(row.nodeLane)
            let center = CGPoint(x: x(lane), y: mid)
            if wipAbove {
                context.setStrokeColor(colors.lane(row.nodeColor))
                context.setLineDash(phase: 0, lengths: [2, 2])
                context.move(to: CGPoint(x: center.x, y: 0))
                context.addLine(to: CGPoint(x: center.x, y: mid))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            drawNode(
                context, at: center,
                color: colors.lane(row.nodeColor).copy(alpha: alpha(lane)) ?? colors.lane(row.nodeColor),
                merge: row.isMerge, head: isHead, style: style)
        }
    }

    private func drawNode(
        _ context: CGContext, at center: CGPoint, color: CGColor, merge: Bool, head: Bool, style: GraphStyle
    ) {
        let metrics = style.metrics
        let colors = style.colors
        if merge {
            // Hollow ring, one step larger.
            let radius = metrics.mergeNodeRadius
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(colors.canvas)
            context.fillEllipse(in: rect)
            context.setStrokeColor(color)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
        } else {
            let radius = metrics.nodeRadius
            // A 1 pt ring in the surface colour separates the disc from its edges.
            let outer = radius + 1
            context.setFillColor(colors.canvas)
            context.fillEllipse(
                in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            context.setFillColor(color)
            context.fillEllipse(
                in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        if head {
            let radius = (merge ? metrics.mergeNodeRadius : metrics.nodeRadius) + metrics.headRingGap
            context.setStrokeColor(colors.headRing)
            context.setLineWidth(metrics.headRingWidth)
            context.strokeEllipse(
                in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}

/// Ref pills and the subject, drawn in one view (no subview per pill, design §4.5).
final class SubjectCellView: NSView {
    struct Content {
        var labels: [RefLabel] = []
        var labelColor: UInt8 = 0
        var subject = ""
        var trailing = ""
        var style: TextStyle = .normal
        var dimmed = false
        var isMatch = false
    }

    enum TextStyle { case normal, placeholder, footer }

    var style: GraphStyle?
    var content = Content() {
        didSet { needsDisplay = true }
    }
    /// Where the pills ended in the last draw (hit-testing for "+N" and label menus).
    private(set) var pillFrames: [(RefLabel?, NSRect)] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let maxPills = 3

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let context = NSGraphicsContext.current?.cgContext else { return }
        let metrics = style.metrics
        let colors = style.colors
        if content.dimmed { context.setAlpha(0.45) }
        var x: CGFloat = Space.s2
        let mid = bounds.height / 2
        pillFrames.removeAll(keepingCapacity: true)
        let visible = content.labels.prefix(Self.maxPills)
        for label in visible {
            let width = drawPill(label, at: x, mid: mid, style: style, context: context)
            pillFrames.append(
                (label, NSRect(x: x, y: mid - metrics.pillHeight / 2, width: width, height: metrics.pillHeight)))
            x += width + metrics.pillSpacing
        }
        if content.labels.count > Self.maxPills {
            let more = RefLabel(kind: .tag, text: "+\(content.labels.count - Self.maxPills)", fullName: nil)
            let width = drawPill(more, at: x, mid: mid, style: style, context: context, neutral: true)
            pillFrames.append(
                (nil, NSRect(x: x, y: mid - metrics.pillHeight / 2, width: width, height: metrics.pillHeight)))
            x += width + metrics.pillSpacing
        }
        if !visible.isEmpty { x += Space.s1 }

        let font: NSFont
        let color: NSColor
        switch content.style {
        case .normal:
            font = style.subjectFont
            color = colors.textPrimary
        case .placeholder:
            font = style.subjectFont
            color = colors.textSecondary
        case .footer:
            font = style.secondaryFont
            color = colors.textTertiary
        }
        let trailingAttributes: [NSAttributedString.Key: Any] = [
            .font: style.secondaryFont, .foregroundColor: colors.textTertiary,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let lineHeight = ceil(font.ascender - font.descender)
        // The subject wins; trailing counts take what is left (truncated if needed).
        let subjectWidth = ceil((content.subject as NSString).size(withAttributes: attributes).width)
        let available = max(0, min(subjectWidth + 1, bounds.width - x - Space.s2))
        let textRect = NSRect(x: x, y: (bounds.height - lineHeight) / 2, width: available, height: lineHeight)
        (content.subject as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        if !content.trailing.isEmpty {
            let used = min(available, (content.subject as NSString).size(withAttributes: attributes).width)
            let secondaryHeight = ceil(style.secondaryFont.ascender - style.secondaryFont.descender)
            (content.trailing as NSString).draw(
                at: NSPoint(x: x + used + Space.s5, y: (bounds.height - secondaryHeight) / 2),
                withAttributes: trailingAttributes)
        }
    }

    /// Draws one opaque tinted pill; returns its width. Never glass (design §3.2).
    private func drawPill(
        _ label: RefLabel, at x: CGFloat, mid: CGFloat, style: GraphStyle, context: CGContext, neutral: Bool = false
    ) -> CGFloat {
        let metrics = style.metrics
        let colors = style.colors
        let slot = content.labelColor
        var leadingGlyphWidth: CGFloat = 0
        var text = label.text
        var font = style.pillFont
        var textColor: NSColor = NSColor(cgColor: colors.lane(slot)) ?? colors.textSecondary
        var fill: CGColor? = colors.laneFills[Int(slot) % colors.laneFills.count]
        var stroke: CGColor?
        var prefix: String?
        switch label.kind {
        case .current:
            font = style.pillBoldFont
            leadingGlyphWidth = 6 + Space.s2
        case .localWithUpstream(let remote, let isCurrent):
            if isCurrent {
                font = style.pillBoldFont
                leadingGlyphWidth = 6 + Space.s2
            }
            text = "\(label.text) ⇄ \(remote)"
        case .local:
            break
        case .remote:
            fill = nil
            stroke = colors.laneOutlines[Int(slot) % colors.laneOutlines.count]
            textColor = colors.textSecondary
            if let slash = label.text.firstIndex(of: "/") {
                prefix = String(label.text[...slash])
                text = String(label.text[label.text.index(after: slash)...])
            }
        case .tag:
            fill = colors.neutralFill
            textColor = colors.textSecondary
            leadingGlyphWidth = neutral ? 0 : 10 + Space.s1
        case .detachedHead:
            fill = colors.neutralFill
            stroke = colors.warning
            textColor = colors.textPrimary
        }
        if neutral {
            fill = colors.neutralFill
            stroke = nil
            textColor = colors.textSecondary
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let prefixAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.textTertiary]
        let prefixWidth = prefix.map { ($0 as NSString).size(withAttributes: prefixAttributes).width } ?? 0
        let maxText: CGFloat = 160
        let textWidth = min(maxText, ceil((text as NSString).size(withAttributes: attributes).width))
        let width = metrics.pillPadding * 2 + leadingGlyphWidth + prefixWidth + textWidth
        let rect = CGRect(x: x, y: (mid - metrics.pillHeight / 2).rounded(), width: width, height: metrics.pillHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: Radius.xs, cornerHeight: Radius.xs, transform: nil)
        if let fill {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        if let stroke {
            context.setStrokeColor(stroke)
            context.setLineWidth(1)
            context.addPath(
                CGPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Radius.xs, cornerHeight: Radius.xs,
                    transform: nil))
            context.strokePath()
        }
        var textX = rect.minX + metrics.pillPadding
        switch label.kind {
        case .current, .localWithUpstream(_, true):
            context.setFillColor(colors.lane(slot))
            context.fillEllipse(in: CGRect(x: textX, y: rect.midY - 3, width: 6, height: 6))
            textX += 6 + Space.s2
        case .tag where !neutral:
            if let image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
            {
                let tinted = image.tinted(colors.textSecondary)
                tinted.draw(in: NSRect(x: textX, y: rect.midY - 5, width: 10, height: 10))
            }
            textX += 10 + Space.s1
        default:
            break
        }
        let lineHeight = ceil(font.ascender - font.descender)
        let textY = rect.midY - lineHeight / 2
        if let prefix {
            (prefix as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: prefixAttributes)
            textX += prefixWidth
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        var truncating = attributes
        truncating[.paragraphStyle] = paragraph
        (text as NSString).draw(
            with: NSRect(x: textX, y: textY, width: textWidth, height: lineHeight), options: [.usesLineFragmentOrigin],
            attributes: truncating)
        return width
    }

    /// The label under a point (context menus on pills).
    func label(at point: NSPoint) -> (label: RefLabel?, isOverflow: Bool)? {
        for (label, frame) in pillFrames where frame.contains(point) {
            return (label, label == nil)
        }
        return nil
    }
}

extension NSImage {
    /// A template image filled with `color` (for drawing symbols inside custom `draw(_:)`).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

/// Initials avatar + author name (no network, design §2).
final class AuthorCellView: NSView {
    var style: GraphStyle?
    var name = "" {
        didSet { needsDisplay = true }
    }
    var initials = ""
    var slot = 0
    var dimmed = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let context = NSGraphicsContext.current?.cgContext, !name.isEmpty else { return }
        if dimmed { context.setAlpha(0.45) }
        let size = style.metrics.avatarSize
        let circle = CGRect(x: Space.s2, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        let lane = style.colors.lanes.isEmpty ? CGColor.black : style.colors.lanes[slot % style.colors.lanes.count]
        context.setFillColor(lane.copy(alpha: style.colors.variant.isDark ? 0.32 : 0.18) ?? lane)
        context.fillEllipse(in: circle)
        let initialsAttributes: [NSAttributedString.Key: Any] = [
            .font: style.avatarFont, .foregroundColor: NSColor(cgColor: lane) ?? style.colors.textSecondary,
        ]
        let initialsSize = (initials as NSString).size(withAttributes: initialsAttributes)
        (initials as NSString).draw(
            at: NSPoint(x: circle.midX - initialsSize.width / 2, y: circle.midY - initialsSize.height / 2),
            withAttributes: initialsAttributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.secondaryFont, .foregroundColor: style.colors.textSecondary, .paragraphStyle: paragraph,
        ]
        let lineHeight = ceil(style.secondaryFont.ascender - style.secondaryFont.descender)
        let x = circle.maxX + Space.s3
        (name as NSString).draw(
            with: NSRect(
                x: x, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - x - Space.s2),
                height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// A single line of secondary text (date, short SHA).
final class TextCellView: NSView {
    var style: GraphStyle?
    var text = "" {
        didSet { needsDisplay = true }
    }
    var monospaced = false
    var dimmed = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let style, !text.isEmpty else { return }
        if dimmed { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
        let font = monospaced ? style.monoFont : style.secondaryFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: monospaced ? style.colors.textTertiary : style.colors.textSecondary,
            .paragraphStyle: paragraph,
        ]
        let lineHeight = ceil(font.ascender - font.descender)
        (text as NSString).draw(
            with: NSRect(
                x: Space.s2, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - Space.s4),
                height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// Row background: hover and selection (system accent at 16 %/24 % + 2 pt leading accent bar).
final class GraphRowView: NSTableRowView {
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateHover(animated: true)
        }
    }
    var isSearchMatch = false {
        didSet { if oldValue != isSearchMatch { needsDisplay = true } }
    }
    private let hoverLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(hoverLayer)
        hoverLayer.opacity = 0
        canDrawSubviewsIntoLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverLayer.backgroundColor = ColorToken.stateHover.nsColor.cgColor
        }
    }

    private func updateHover(animated: Bool) {
        if hoverLayer.backgroundColor == nil {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                hoverLayer.backgroundColor = ColorToken.stateHover.nsColor.cgColor
            }
        }
        CATransaction.begin()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(isHovered ? MotionToken.hover.duration : 0.14)
        }
        hoverLayer.opacity = isHovered ? 1 : 0
        CATransaction.commit()
    }

    func resetHover() {
        isHovered = false
        updateHover(animated: false)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isSearchMatch && !isSelected {
            let isDark = Variant.resolve(effectiveAppearance).isDark
            NSColor.findHighlightColor.withAlphaComponent(isDark ? 0.18 : 0.22).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let isDark = Variant.resolve(effectiveAppearance).isDark
        NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.24 : 0.16).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
