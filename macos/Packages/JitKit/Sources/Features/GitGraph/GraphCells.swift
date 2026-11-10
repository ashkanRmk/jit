import AppKit
import DesignSystem
import GitCore

/// Shared, per-appearance drawing state for every graph cell (resolved once, not per draw).
@MainActor final class GraphStyle {
    var metrics: GraphMetrics {
        didSet { avatars.removeAll() }
    }
    let colors = GraphColorTable()
    private(set) var subjectFont = GraphTypography.subject
    private(set) var pillFont = GraphTypography.pill
    private(set) var pillBoldFont = GraphTypography.pillEmphasized
    private(set) var secondaryFont = GraphTypography.secondary
    private(set) var monoFont = GraphTypography.mono
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Rendered avatar nodes, blitted per draw (no text layout per row, P2.13).
    struct AvatarKey: Hashable {
        let initials: String
        let authorSlot: Int
        let laneSlot: UInt8
        let diameter: CGFloat
        let scale: CGFloat
        /// The author's picture, when one is known (identity only: a new picture is a new key).
        var photo: ObjectIdentifier?
    }
    /// Looks up an author's picture by email (`AvatarStore`); `nil` keeps initials.
    var photo: ((String) -> CGImage?)?
    private var avatars: [AvatarKey: CGImage] = [:]
    private var symbols: [String: NSImage] = [:]
    static let maxCachedAvatars = CacheLimits.graphAvatars

    init(density: Density) {
        metrics = .forDensity(density)
    }

    func update(appearance: NSAppearance) -> Bool {
        let changed = colors.update(for: appearance)
        if changed {
            avatars.removeAll()
            symbols.removeAll()
        }
        return changed
    }

    var cachedAvatarCount: Int { avatars.count }

    /// The avatar node image for `key`, rendered once per appearance.
    func avatar(_ key: AvatarKey, photo: CGImage? = nil) -> CGImage? {
        if let image = avatars[key] { return image }
        if avatars.count >= Self.maxCachedAvatars { avatars.removeAll(keepingCapacity: true) }
        let image = renderAvatar(key, photo: photo)
        avatars[key] = image
        return image
    }

    private func renderAvatar(_ key: AvatarKey, photo: CGImage?) -> CGImage? {
        let pixels = Int((key.diameter * key.scale).rounded(.up))
        guard pixels > 0,
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: key.scale, y: key.scale)
        let diameter = key.diameter
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let ring = metrics.nodeRing
        let author = colors.lanes.isEmpty ? CGColor.black : colors.lanes[key.authorSlot % colors.lanes.count]
        // Opaque disc (edges never show through), author tint, then the lane ring.
        context.setFillColor(colors.canvas)
        context.fillEllipse(in: rect)
        if let photo {
            // The picture fills the disc inside the lane ring.
            context.saveGState()
            context.addEllipse(in: rect.insetBy(dx: ring / 2, dy: ring / 2))
            context.clip()
            context.interpolationQuality = .high
            context.draw(photo, in: rect)
            context.restoreGState()
            context.setStrokeColor(colors.lane(key.laneSlot))
            context.setLineWidth(ring)
            context.strokeEllipse(in: rect.insetBy(dx: ring / 2, dy: ring / 2))
            return context.makeImage()
        }
        context.setFillColor(author.copy(alpha: colors.variant.isDark ? 0.32 : 0.22) ?? author)
        context.fillEllipse(in: rect.insetBy(dx: ring, dy: ring))
        context.setStrokeColor(colors.lane(key.laneSlot))
        context.setLineWidth(ring)
        context.strokeEllipse(in: rect.insetBy(dx: ring / 2, dy: ring / 2))
        let font = GraphTypography.nodeInitials(diameter: diameter)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(cgColor: author) ?? colors.textSecondary,
        ]
        let text = key.initials as NSString
        let width = text.size(withAttributes: attributes).width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // Unflipped: the draw point is the line's bottom-left; centre the cap height on the disc.
        let baseline = (diameter - font.capHeight) / 2
        text.draw(at: NSPoint(x: (diameter - width) / 2, y: baseline + font.descender), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// An SF Symbol tinted once per appearance (pill glyphs).
    func symbol(_ name: String, color: NSColor, slot: Int, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)|\(slot)|\(pointSize)"
        if let image = symbols[key] { return image }
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        else { return nil }
        let tinted = image.tinted(color)
        symbols[key] = tinted
        return tinted
    }
}

/// Per-row decoration for a commit node.
struct NodeDecor: Equatable {
    var initials = ""
    var email = ""
    var avatarSlot = 0
    /// Shown when the pointer rests on the node.
    var toolTip = ""
    /// The row has ref labels: a connector runs from the ref column to the node.
    var hasRefs = false
    var wipAbove = false
    var dimmed = false
}

/// What a graph cell draws for one row.
enum GraphCellContent {
    case commit(CommitRow, NodeDecor)
    /// The working-directory row: dashed node on HEAD's lane, dashed edge down into HEAD's row.
    case wip(lane: Int, color: UInt8)
    /// "Show only matches": topology is meaningless, a node on lane 0 only.
    case flat(isMerge: Bool, color: UInt8, NodeDecor)
    case empty
}

/// Draws one row's lanes and node with Core Graphics (P2.13). Fully determined by its row, so rows are
/// reusable and drawable in isolation. Decorative for accessibility (the row carries the label).
final class GraphCellView: NSView {
    var style: GraphStyle?
    var content: GraphCellContent = .empty {
        didSet {
            needsDisplay = true
            updateNodeToolTip()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateNodeToolTip()
    }

    /// The node (avatar or merge dot) answers with the author; the rest of the cell has no tooltip.
    private func updateNodeToolTip() {
        guard let style else { return }
        var lane = 0
        var text = ""
        switch content {
        case .commit(let row, let decor):
            lane = Int(row.nodeLane)
            text = decor.toolTip
        case .flat(_, _, let decor):
            text = decor.toolTip
        case .wip, .empty:
            break
        }
        let diameter = style.metrics.nodeDiameter + 4
        let rect =
            text.isEmpty
            ? NSRect.zero
            : NSRect(
                x: style.metrics.laneX(lane) - diameter / 2, y: (bounds.height - diameter) / 2, width: diameter,
                height: diameter
            ).intersection(bounds)
        nodeToolTip = text
        // The text is asked for when the tooltip shows; the tracking rect changes only when the node moves.
        guard rect != nodeToolTipRect else { return }
        removeAllToolTips()
        nodeToolTipRect = rect
        if !rect.isEmpty { addToolTip(rect, owner: self, userData: nil) }
    }
    private var nodeToolTip = ""
    private var nodeToolTipRect = NSRect.zero

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
        context.setLineJoin(.round)

        func x(_ lane: Int) -> CGFloat {
            GraphMetrics.snap(metrics.laneX(lane), width: metrics.edgeWidth, scale: scale)
        }
        func alpha(_ lane: Int) -> CGFloat { lane >= metrics.maxVisibleLanes ? 0.5 : 1 }

        switch content {
        case .empty:
            return
        case .flat(let isMerge, let color, let decor):
            drawNode(
                context, lane: 0, x: x(0), mid: mid, color: color, isMerge: isMerge, decor: decor, scale: scale,
                style: style)
        case .wip(let lane, let color):
            let cx = x(lane)
            let radius = metrics.nodeDiameter / 2
            context.setStrokeColor(colors.lane(color))
            context.setLineWidth(metrics.edgeWidth)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: cx, y: mid + radius))
            context.addLine(to: CGPoint(x: cx, y: height))
            context.strokePath()
            let ring = metrics.nodeRing
            let rect = CGRect(x: cx - radius, y: mid - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(colors.canvas)
            context.fillEllipse(in: rect)
            context.setLineWidth(ring)
            context.strokeEllipse(in: rect.insetBy(dx: ring / 2, dy: ring / 2))
            context.setLineDash(phase: 0, lengths: [])
        case .commit(let row, let decor):
            if decor.dimmed { context.setAlpha(0.45) }
            let lane = Int(row.nodeLane)
            let cx = x(lane)
            drawBand(context, x: cx, mid: mid, color: row.nodeColor, hasRefs: decor.hasRefs, style: style)
            context.setLineWidth(metrics.edgeWidth)
            for segment in row.segments {
                let from = Int(segment.fromLane)
                let to = Int(segment.toLane)
                context.setStrokeColor(
                    colors.lane(segment.color).copy(alpha: alpha(max(from, to))) ?? colors.lane(segment.color))
                context.addPath(
                    GraphEdgeGeometry.path(x0: x(from), x1: x(to), half: segment.half, mid: mid, height: height))
                context.strokePath()
            }
            if decor.wipAbove {
                context.setStrokeColor(colors.lane(row.nodeColor))
                context.setLineDash(phase: 0, lengths: [3, 3])
                context.move(to: CGPoint(x: cx, y: 0))
                context.addLine(to: CGPoint(x: cx, y: mid))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            if lane >= metrics.maxVisibleLanes { context.setAlpha(decor.dimmed ? 0.25 : 0.5) }
            drawNode(
                context, lane: lane, x: cx, mid: mid, color: row.nodeColor, isMerge: row.isMerge, decor: decor,
                scale: scale, style: style, bandDrawn: true)
        }
    }

    /// Lane-tinted band from the node to the column's trailing edge, a trailing lane bar, and the connector
    /// from the ref column (drawn under the edges).
    private func drawBand(
        _ context: CGContext, x cx: CGFloat, mid: CGFloat, color: UInt8, hasRefs: Bool, style: GraphStyle
    ) {
        let metrics = style.metrics
        let colors = style.colors
        let diameter = metrics.nodeDiameter
        let top = mid - diameter / 2
        context.setFillColor(colors.laneFills[Int(color) % max(1, colors.laneFills.count)])
        context.fill(CGRect(x: cx, y: top, width: max(0, bounds.width - cx), height: diameter))
        context.setFillColor(colors.lane(color))
        context.fill(
            CGRect(
                x: bounds.width - GraphMetrics.laneBarWidth, y: top, width: GraphMetrics.laneBarWidth, height: diameter)
        )
        if hasRefs {
            context.setStrokeColor(colors.laneOutlines[Int(color) % max(1, colors.laneOutlines.count)])
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: mid + 0.5))
            context.addLine(to: CGPoint(x: cx, y: mid + 0.5))
            context.strokePath()
        }
    }

    private func drawNode(
        _ context: CGContext, lane: Int, x cx: CGFloat, mid: CGFloat, color: UInt8, isMerge: Bool, decor: NodeDecor,
        scale: CGFloat, style: GraphStyle, bandDrawn: Bool = false
    ) {
        let metrics = style.metrics
        let colors = style.colors
        if !bandDrawn {
            if decor.dimmed { context.setAlpha(0.45) }
            drawBand(context, x: cx, mid: mid, color: color, hasRefs: decor.hasRefs, style: style)
        }
        if isMerge {
            let radius = metrics.mergeDotDiameter / 2
            context.setFillColor(colors.lane(color))
            context.fillEllipse(in: CGRect(x: cx - radius, y: mid - radius, width: radius * 2, height: radius * 2))
            return
        }
        let diameter = metrics.nodeDiameter
        let photo = decor.email.isEmpty ? nil : style.photo?(decor.email)
        let key = GraphStyle.AvatarKey(
            initials: decor.initials, authorSlot: decor.avatarSlot, laneSlot: color, diameter: diameter, scale: scale,
            photo: photo.map { ObjectIdentifier($0) })
        guard let image = style.avatar(key, photo: photo) else { return }
        let rect = CGRect(x: cx - diameter / 2, y: mid - diameter / 2, width: diameter, height: diameter)
        // The view is flipped; CGImages draw bottom-up.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

extension GraphCellView: @MainActor NSViewToolTipOwner {
    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?
    )
        -> String
    { nodeToolTip }
}

/// The subject (and WIP counts / footer), drawn in one view.
final class SubjectCellView: NSView {
    struct Content {
        var subject = ""
        var trailing = ""
        var style: TextStyle = .normal
        var dimmed = false
    }

    enum TextStyle { case normal, placeholder, footer }

    var style: GraphStyle?
    var content = Content() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = style.colors
        if content.dimmed { context.setAlpha(0.45) }
        let x: CGFloat = Space.s3
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
            let secondaryHeight = ceil(style.secondaryFont.ascender - style.secondaryFont.descender)
            (content.trailing as NSString).draw(
                at: NSPoint(x: x + available + Space.s5, y: (bounds.height - secondaryHeight) / 2),
                withAttributes: trailingAttributes)
        }
    }
}

/// The "Branch / Tag" column (P2.13): the row's first ref as a pill, `+N` for the rest, and a connector
/// towards the node. One view, no subview per pill (design §4.5). Hovering the cell shows every label in
/// full in `RefsHoverView`, which also owns the tooltips.
final class RefsCellView: NSView {
    struct Content {
        var labels: [RefLabel] = []
        var labelColor: UInt8 = 0
        var dimmed = false
        /// The graph column is the next column: the connector runs to the trailing edge.
        var connects = true
    }

    var style: GraphStyle?
    var content = Content() {
        didSet { needsDisplay = true }
    }
    /// Where the pills were drawn in the last draw (`nil` label = the `+N` overflow pill).
    private(set) var pillFrames: [(RefLabel?, NSRect)] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        pillFrames.removeAll(keepingCapacity: true)
        guard let style, let context = NSGraphicsContext.current?.cgContext, let first = content.labels.first
        else { return }
        let metrics = style.metrics
        let colors = style.colors
        if content.dimmed { context.setAlpha(0.45) }
        let mid = (bounds.height / 2).rounded()
        let slot = content.labelColor
        let painter = PillPainter(style: style, slot: slot)
        let leading = Space.s2
        var overflow: RefLabel?
        var overflowWidth: CGFloat = 0
        if content.labels.count > 1 {
            let more = RefLabel(kind: .tag, text: "+\(content.labels.count - 1)", fullName: nil)
            overflow = more
            overflowWidth = painter.width(more, neutral: true) + metrics.pillSpacing
        }
        // Keep a short stub of connector visible after the pills.
        let maxFirst = max(metrics.pillHeight, bounds.width - leading - overflowWidth - Space.s3)
        var x = leading
        let width = painter.draw(first, at: x, mid: mid, maxWidth: maxFirst, context: context)
        pillFrames.append(
            (first, NSRect(x: x, y: mid - metrics.pillHeight / 2, width: width, height: metrics.pillHeight)))
        x += width
        if let overflow {
            x += metrics.pillSpacing
            let moreWidth = painter.draw(
                overflow, at: x, mid: mid, maxWidth: overflowWidth, context: context, neutral: true)
            pillFrames.append(
                (nil, NSRect(x: x, y: mid - metrics.pillHeight / 2, width: moreWidth, height: metrics.pillHeight)))
            x += moreWidth
        }
        if content.connects, x < bounds.width {
            context.setStrokeColor(colors.laneOutlines[Int(slot) % max(1, colors.laneOutlines.count)])
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: mid + 0.5))
            context.addLine(to: CGPoint(x: bounds.width, y: mid + 0.5))
            context.strokePath()
        }
    }

    /// The label under a point (context menus on pills).
    func label(at point: NSPoint) -> (label: RefLabel?, isOverflow: Bool)? {
        for (label, frame) in pillFrames where frame.contains(point) {
            return (label, label == nil)
        }
        return nil
    }
}

/// A part of a drawn pill with its own tooltip (the location glyphs, the name).
struct PillRegion {
    let rect: NSRect
    let toolTip: String
}

/// Draws (or measures) one opaque tinted ref pill. Never glass (design §3.2). Where a branch lives is shown
/// with glyphs instead of text: a computer for a local branch, a cloud for a remote one, both when a local
/// branch and its upstream sit on the same commit.
@MainActor struct PillPainter {
    let style: GraphStyle
    let slot: UInt8

    static let localSymbol = "laptopcomputer"
    static let remoteSymbol = "cloud"

    private struct Glyph {
        var name: String
        var color: NSColor
        var width: CGFloat
        var neutral = false
        var toolTip: String?
    }

    private struct Layout {
        var text: String
        var font: NSFont
        var textColor: NSColor
        var fill: CGColor?
        var stroke: CGColor?
        var glyphs: [Glyph] = []
        var toolTip: String
    }

    private func layout(_ label: RefLabel, neutral: Bool) -> Layout {
        let colors = style.colors
        let laneText = NSColor(cgColor: colors.lane(slot)) ?? colors.textSecondary
        var result = Layout(
            text: label.text, font: style.pillFont, textColor: laneText,
            fill: colors.laneFills[Int(slot) % max(1, colors.laneFills.count)], stroke: nil, toolTip: label.text)
        let check = Glyph(name: "checkmark", color: laneText, width: 10, toolTip: "Checked out")
        let local = Glyph(name: Self.localSymbol, color: laneText, width: 13, toolTip: "Local branch \(label.text)")
        switch label.kind {
        case .current:
            result.font = style.pillBoldFont
            result.glyphs = [check, local]
            result.toolTip = "\(label.text) — current branch, local only"
        case .localWithUpstream(let remote, let isCurrent):
            if isCurrent {
                result.font = style.pillBoldFont
                result.glyphs = [check]
            }
            let upstream = label.upstream ?? "\(remote)/\(label.text)"
            result.glyphs += [
                local, Glyph(name: Self.remoteSymbol, color: laneText, width: 13, toolTip: upstream),
            ]
            result.toolTip = "\(label.text) — local and \(upstream)"
        case .local:
            result.glyphs = [local]
            result.toolTip = "\(label.text) — local only"
        case .remote:
            result.fill = nil
            result.stroke = colors.laneOutlines[Int(slot) % max(1, colors.laneOutlines.count)]
            result.textColor = colors.textSecondary
            if let slash = label.text.firstIndex(of: "/") {
                result.text = String(label.text[label.text.index(after: slash)...])
            }
            result.glyphs = [
                Glyph(
                    name: Self.remoteSymbol, color: colors.textSecondary, width: 13, neutral: true,
                    toolTip: label.text)
            ]
            result.toolTip = "\(label.text) — remote only"
        case .tag:
            result.fill = colors.neutralFill
            result.textColor = colors.textSecondary
            if !neutral {
                result.glyphs = [
                    Glyph(name: "tag", color: colors.textSecondary, width: 10, neutral: true, toolTip: nil)
                ]
            }
            result.toolTip = "Tag \(label.text)"
        case .detachedHead:
            result.fill = colors.neutralFill
            result.stroke = colors.warning
            result.textColor = colors.textPrimary
            result.toolTip = "HEAD is detached at this commit"
        }
        if neutral {
            result.fill = colors.neutralFill
            result.stroke = nil
            result.textColor = colors.textSecondary
            result.glyphs = []
        }
        return result
    }

    private func glyphsWidth(_ layout: Layout) -> CGFloat {
        layout.glyphs.reduce(0) { $0 + $1.width + Space.s1 }
    }

    func width(_ label: RefLabel, neutral: Bool = false) -> CGFloat {
        let layout = layout(label, neutral: neutral)
        let text = ceil((layout.text as NSString).size(withAttributes: [.font: layout.font]).width)
        return style.metrics.pillPadding * 2 + glyphsWidth(layout) + text
    }

    /// The tooltip regions of `label` drawn at `x` with `width` (as returned by `draw`).
    func regions(_ label: RefLabel, at x: CGFloat, mid: CGFloat, width: CGFloat) -> [PillRegion] {
        let metrics = style.metrics
        let layout = layout(label, neutral: false)
        let top = (mid - metrics.pillHeight / 2).rounded()
        var result: [PillRegion] = []
        var glyphX = x + metrics.pillPadding
        var nameStart = x
        for (index, glyph) in layout.glyphs.enumerated() {
            let end = glyphX + glyph.width + Space.s1
            if let toolTip = glyph.toolTip {
                // The first glyph's region starts at the pill's edge so no sliver is left without a tooltip.
                let start = index == 0 ? x : glyphX
                result.append(
                    PillRegion(
                        rect: NSRect(x: start, y: top, width: end - start, height: metrics.pillHeight),
                        toolTip: toolTip))
                nameStart = end
            } else if index == 0 {
                nameStart = x
            }
            glyphX = end
        }
        if x + width > nameStart {
            result.append(
                PillRegion(
                    rect: NSRect(x: nameStart, y: top, width: x + width - nameStart, height: metrics.pillHeight),
                    toolTip: layout.toolTip))
        }
        return result
    }

    /// Draws `label` no wider than `maxWidth` (the name truncates in the middle); returns its width.
    func draw(
        _ label: RefLabel, at x: CGFloat, mid: CGFloat, maxWidth: CGFloat, context: CGContext, neutral: Bool = false
    ) -> CGFloat {
        let metrics = style.metrics
        let layout = layout(label, neutral: neutral)
        let glyphWidth = glyphsWidth(layout)
        let attributes: [NSAttributedString.Key: Any] = [.font: layout.font, .foregroundColor: layout.textColor]
        let measured = ceil((layout.text as NSString).size(withAttributes: attributes).width)
        let textWidth = max(0, min(measured, maxWidth - metrics.pillPadding * 2 - glyphWidth))
        let width = metrics.pillPadding * 2 + glyphWidth + textWidth
        let rect = CGRect(x: x, y: (mid - metrics.pillHeight / 2).rounded(), width: width, height: metrics.pillHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: Radius.xs, cornerHeight: Radius.xs, transform: nil)
        if let fill = layout.fill {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        if let stroke = layout.stroke {
            context.setStrokeColor(stroke)
            context.setLineWidth(1)
            context.addPath(
                CGPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Radius.xs, cornerHeight: Radius.xs,
                    transform: nil))
            context.strokePath()
        }
        var textX = rect.minX + metrics.pillPadding
        for glyph in layout.glyphs {
            let image = style.symbol(
                glyph.name, color: glyph.color, slot: glyph.neutral ? -1 : Int(slot), pointSize: 9,
                weight: glyph.name == "checkmark" ? .bold : .medium)
            if let image, image.size.width > 0 {
                // Symbols are not square: fit the glyph's width, keep the aspect ratio.
                let scale = min(glyph.width / image.size.width, (metrics.pillHeight - 6) / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(
                    in: NSRect(
                        x: textX + (glyph.width - size.width) / 2, y: rect.midY - size.height / 2, width: size.width,
                        height: size.height))
            }
            textX += glyph.width + Space.s1
        }
        let lineHeight = ceil(layout.font.ascender - layout.font.descender)
        let textY = rect.midY - lineHeight / 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        var truncating = attributes
        truncating[.paragraphStyle] = paragraph
        (layout.text as NSString).draw(
            with: NSRect(x: textX, y: textY, width: textWidth, height: lineHeight), options: [.usesLineFragmentOrigin],
            attributes: truncating)
        return width
    }
}

/// Every ref label of the hovered row, in full (the cell shows one pill and `+N`). Sits over the row,
/// starting at the ref column and growing over the columns after it; opaque, so nothing shows through.
/// Owns the label tooltips. Mouse events go to the table underneath.
final class RefsHoverView: NSView {
    private(set) var row = -1
    private(set) var pillFrames: [(RefLabel, NSRect)] = []
    private var regions: [PillRegion] = []
    private var labels: [RefLabel] = []
    private var slot: UInt8 = 0
    private var isSelectedRow = false
    private var style: GraphStyle?
    private weak var table: NSTableView?
    private var generation = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Redraws are not needed while the width animates: the content keeps its place, the clip grows.
        layer?.contentsGravity = .topLeft
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The width that shows every label in full.
    static func naturalWidth(_ labels: [RefLabel], style: GraphStyle, slot: UInt8) -> CGFloat {
        let painter = PillPainter(style: style, slot: slot)
        let pills = labels.reduce(CGFloat(0)) { $0 + painter.width($1) }
        return Space.s2 + pills + CGFloat(max(0, labels.count - 1)) * style.metrics.pillSpacing + Space.s3
    }

    /// Shows the labels of `row` starting at `cellFrame` (table coordinates), growing to the width they need
    /// (never past `maxWidth`).
    func show(
        row: Int, labels: [RefLabel], slot: UInt8, isSelected: Bool, style: GraphStyle, cellFrame: NSRect,
        maxWidth: CGFloat, in table: NSTableView
    ) {
        generation += 1
        self.row = row
        self.labels = labels
        self.slot = slot
        self.style = style
        self.table = table
        isSelectedRow = isSelected
        let width = min(max(cellFrame.width, Self.naturalWidth(labels, style: style, slot: slot)), maxWidth)
        layoutPills(width: width, height: cellFrame.height)
        if superview !== table { table.addSubview(self) }
        isHidden = false
        alphaValue = 1
        let target = NSRect(x: cellFrame.minX, y: cellFrame.minY, width: width, height: cellFrame.height)
        // Draw at the final size first, then reveal it from the cell's width.
        frame = target
        needsDisplay = true
        displayIfNeeded()
        guard !style.reduceMotion, width > cellFrame.width + 0.5 else { return }
        frame = cellFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionToken.select.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().frame = target
        }
    }

    func hide(animated: Bool = true) {
        guard !isHidden else { return }
        row = -1
        generation += 1
        let current = generation
        removeAllToolTips()
        guard animated, style?.reduceMotion == false else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionToken.feedbackOut.duration
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.isHidden = true
            }
        }
    }

    private func layoutPills(width: CGFloat, height: CGFloat) {
        pillFrames.removeAll(keepingCapacity: true)
        regions.removeAll(keepingCapacity: true)
        removeAllToolTips()
        guard let style else { return }
        let metrics = style.metrics
        let painter = PillPainter(style: style, slot: slot)
        let mid = (height / 2).rounded()
        var x = Space.s2
        for (index, label) in labels.enumerated() {
            // Labels that still do not fit (very long names in a narrow window) truncate, the last one first.
            let remaining = width - x - Space.s3
            let later = labels[(index + 1)...].reduce(CGFloat(0)) {
                $0 + min(painter.width($1), 60) + metrics.pillSpacing
            }
            let pillWidth = max(metrics.pillHeight, min(painter.width(label), remaining - later))
            let frame = NSRect(x: x, y: mid - metrics.pillHeight / 2, width: pillWidth, height: metrics.pillHeight)
            pillFrames.append((label, frame))
            regions += painter.regions(label, at: x, mid: mid, width: pillWidth)
            x += pillWidth + metrics.pillSpacing
        }
        for region in regions { addToolTip(region.rect, owner: self, userData: nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style, let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = style.colors
        // The row's own look (canvas + hover or selection), opaque.
        context.setFillColor(colors.canvas)
        context.fill(bounds)
        if isSelectedRow {
            NSColor.controlAccentColor.withAlphaComponent(colors.variant.isDark ? 0.24 : 0.16).setFill()
        } else {
            ColorToken.stateHover.nsColor.setFill()
        }
        bounds.fill(using: .sourceOver)
        let painter = PillPainter(style: style, slot: slot)
        let mid = (bounds.height / 2).rounded()
        for (label, frame) in pillFrames {
            _ = painter.draw(label, at: frame.minX, mid: mid, maxWidth: frame.width, context: context)
        }
    }

    func label(at point: NSPoint) -> RefLabel? {
        pillFrames.first { $0.1.contains(point) }?.0
    }

    // MARK: Events go to the table (selection, context menus, double-click)

    override func mouseDown(with event: NSEvent) { table?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { table?.rightMouseDown(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { table?.menu(for: event) }
}

extension RefsHoverView: @MainActor NSViewToolTipOwner {
    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?
    )
        -> String
    {
        regions.first { $0.rect.contains(point) }?.toolTip ?? ""
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

/// Author name (the avatar is on the graph node, P2.13).
final class AuthorCellView: NSView {
    var style: GraphStyle?
    var name = "" {
        didSet { needsDisplay = true }
    }
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
        guard let style, !name.isEmpty else { return }
        if dimmed { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.secondaryFont, .foregroundColor: style.colors.textSecondary, .paragraphStyle: paragraph,
        ]
        let lineHeight = ceil(style.secondaryFont.ascender - style.secondaryFont.descender)
        (name as NSString).draw(
            with: NSRect(
                x: Space.s2, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - Space.s4),
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
