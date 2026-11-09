import AppKit
import CoreText
import DesignSystem
import GitCore
import Services

/// What one cell (one column of one row) shows.
public struct CodeCell: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case context, added, deleted
        /// Side-by-side filler opposite an addition or deletion.
        case filler
        /// `@@ … @@` header, collapsed-context gap, or file header: one full-width row.
        case hunk, gap, file
        /// Conflict resolver (P4.12): an unresolved block's line, a resolved block's line, a marker line.
        case conflict, resolved, marker
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
    /// "No newline at end of file" and similar, drawn dimmed after the text.
    public var note: String?

    public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String = "", note: String? = nil) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.note = note
    }

    public var isFullWidth: Bool { kind == .hunk || kind == .gap || kind == .file }
}

/// Supplies rows on demand; only visible rows are asked for (ADR-0011).
@MainActor public protocol CodeLinesDataSource: AnyObject {
    var rowCount: Int { get }
    /// 1 (unified, full file) or 2 (side by side).
    var columnCount: Int { get }
    /// Longest text in characters (sets the scrollable width; monospaced font).
    var maxColumnCharacters: Int { get }
    /// Widest line number, for the gutter.
    var maxLineNumber: Int { get }
    /// Number columns per text column (2 for a unified diff: old and new; 1 otherwise).
    var lineNumberColumns: Int { get }
    func cell(row: Int, column: Int) -> CodeCell
    func isSelected(row: Int, column: Int) -> Bool
    /// UTF-16 ranges to highlight (search matches); `current` is the focused match.
    func highlights(row: Int, column: Int) -> (ranges: [NSRange], current: NSRange?)
    /// Word-level changed ranges (UTF-16) inside an added/deleted line.
    func emphasis(row: Int, column: Int) -> [NSRange]
    /// Syntax colours (UTF-16 ranges) for the cell's text.
    func syntax(row: Int, column: Int) -> [(NSRange, NSColor)]
}

extension CodeLinesDataSource {
    public var lineNumberColumns: Int { columnCount == 1 ? 2 : 1 }
    public func emphasis(row: Int, column: Int) -> [NSRange] { [] }
    public func syntax(row: Int, column: Int) -> [(NSRange, NSColor)] { [] }
}

@MainActor public protocol CodeLinesDelegate: AnyObject {
    func codeLines(_ view: CodeLinesView, clickedRow row: Int, column: Int, modifiers: NSEvent.ModifierFlags)
    func codeLines(_ view: CodeLinesView, draggedTo row: Int, column: Int)
    func codeLines(_ view: CodeLinesView, keyDown event: NSEvent) -> Bool
    func codeLinesCopyText(_ view: CodeLinesView) -> String?
    func codeLines(_ view: CodeLinesView, accessibilityLabelFor row: Int) -> String
}

/// A virtualized code/diff renderer (ADR-0011): fixed row height, draws only the rows in the dirty rect,
/// caches `CTLine`s for recently drawn rows, gutters and backgrounds drawn directly. Content layer:
/// opaque, no glass. Reused by blame (P3.9) and the Phase 4 conflict resolver.
public final class CodeLinesView: NSView {
    public weak var dataSource: any CodeLinesDataSource? {
        didSet { reloadData() }
    }
    public weak var delegate: any CodeLinesDelegate?

    public private(set) var font = CodeTextScale.font(step: CodeLinesView.preferredTextSizeStep)
    /// View ▸ Larger / Smaller Code Text (P6.10). Follows the preference unless set explicitly.
    public var textSizeStep = CodeLinesView.preferredTextSizeStep {
        didSet {
            guard textSizeStep != oldValue else { return }
            font = CodeTextScale.font(step: textSizeStep)
            measureFont()
            clearCache()
            reloadData()
        }
    }
    /// The saved preference (`PreferencesStore.codeTextSize`, standard defaults).
    static var preferredTextSizeStep: Int { UserDefaults.standard.integer(forKey: "codeTextSize") }
    nonisolated(unsafe) private var textSizeObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var trimObserver: (any NSObjectProtocol)?
    /// Cached `CTLine`s (tests: bounded by `CacheLimits.codeLines`).
    var cachedLineCount: Int { cache.count }
    public private(set) var rowHeight: CGFloat = TypeToken.monoBody.lineHeight
    public private(set) var characterWidth: CGFloat = 7
    /// Spaces per tab.
    public var tabWidth = 4 { didSet { clearCache() } }
    /// Draws `·` for spaces and `→` for tabs.
    public var showsWhitespace = false { didSet { clearCache() } }
    /// Extra gutter on the left of each column (blame, Phase 4 markers).
    public var leadingGutter: CGFloat = 0 { didSet { reloadData() } }
    /// Drawn in `leadingGutter` for each row (blame).
    public var drawLeadingGutter: ((_ row: Int, _ rect: NSRect) -> Void)?
    /// A click inside `leadingGutter`.
    public var onGutterClick: ((Int) -> Void)?
    /// Tooltip text for a row (blame hover).
    public var toolTipProvider: ((Int) -> String?)? {
        didSet {
            removeAllToolTips()
            if toolTipProvider != nil { addToolTip(bounds, owner: self, userData: nil) }
        }
    }

    private var cache: [CacheKey: CTLine] = [:]
    private var cacheOrder: [CacheKey] = []
    private static let cacheLimit = CacheLimits.codeLines
    private var accessibilityRows: [Int: NSAccessibilityElement] = [:]

    private struct CacheKey: Hashable {
        let row: Int
        let column: Int
        let generation: Int
    }
    private var generation = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        measureFont()
        textSizeObserver = NotificationCenter.default.addObserver(
            forName: PreferencesStore.codeTextSizeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.textSizeStep = Self.preferredTextSizeStep }
        }
        trimObserver = NotificationCenter.default.addObserver(
            forName: CacheLimits.trimNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearCache(releasingStorage: true) }
        }
        setAccessibilityRole(.list)
        setAccessibilityLabel("Diff")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        textSizeObserver.map(NotificationCenter.default.removeObserver)
        trimObserver.map(NotificationCenter.default.removeObserver)
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { false }

    private func measureFont() {
        let attributed = NSAttributedString(string: "0", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        characterWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        rowHeight = max(TypeToken.monoBody.lineHeight, ceil(font.ascender - font.descender + font.leading) + 2)
    }

    // MARK: Geometry

    public var gutterWidth: CGFloat {
        let digits = max(3, String(dataSource?.maxLineNumber ?? 0).count)
        let numbers = dataSource?.lineNumberColumns ?? 2
        return leadingGutter + CGFloat(numbers * digits) * characterWidth + CGFloat(numbers) * Space.s4 + Space.s5
    }

    /// Longest part of one line that is laid out and drawn (UTF-16 units). A minified file's single 5 MB line
    /// otherwise costs hundreds of MB of glyph storage and GPU surfaces (P6.6, large-diff benchmark); the rest
    /// of such a line is summarized as "+N characters not shown". Copy and line actions use the document.
    public static let maxRenderedCharacters = CacheLimits.renderedLineCharacters

    public var columnWidth: CGFloat {
        let columns = CGFloat(dataSource?.columnCount ?? 1)
        let visible = (enclosingScrollView?.contentSize.width ?? bounds.width) / columns
        // Room for the longest rendered prefix plus its "not shown" note.
        let characters = min(dataSource?.maxColumnCharacters ?? 0, Self.maxRenderedCharacters + 40)
        let content = gutterWidth + CGFloat(characters) * characterWidth + Space.s8
        return columns == 1 ? max(visible, content) : visible
    }

    public func reloadData() {
        clearCache()
        let rows = CGFloat(dataSource?.rowCount ?? 0)
        let columns = CGFloat(dataSource?.columnCount ?? 1)
        let width = columns == 1 ? columnWidth : (enclosingScrollView?.contentSize.width ?? bounds.width)
        let height = max(rows * rowHeight, enclosingScrollView?.contentSize.height ?? 0)
        setFrameSize(NSSize(width: width, height: height))
        accessibilityRows = [:]
        needsDisplay = true
    }

    /// Redraws rows whose selection/highlight changed (text cache kept).
    public func refreshRows() { needsDisplay = true }

    public func invalidateText() {
        clearCache()
        needsDisplay = true
    }

    private func clearCache(releasingStorage: Bool = false) {
        generation &+= 1
        cache.removeAll(keepingCapacity: !releasingStorage)
        cacheOrder.removeAll(keepingCapacity: !releasingStorage)
    }

    public func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
    }

    public func row(at point: NSPoint) -> Int? {
        guard let count = dataSource?.rowCount, count > 0 else { return nil }
        let row = Int(point.y / rowHeight)
        return (0..<count).contains(row) ? row : nil
    }

    public func column(at point: NSPoint) -> Int {
        let columns = dataSource?.columnCount ?? 1
        guard columns > 1 else { return 0 }
        return min(columns - 1, max(0, Int(point.x / (bounds.width / CGFloat(columns)))))
    }

    /// Scrolls so `row` is visible (centred when `center`).
    public func scrollToRow(_ row: Int, center: Bool = false) {
        var rect = rowRect(row)
        if center, let visible = enclosingScrollView?.documentVisibleRect {
            rect = rect.insetBy(dx: 0, dy: -(visible.height - rowHeight) / 2)
        }
        scrollToVisible(rect)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        ColorToken.surfaceCanvas.nsColor.setFill()
        dirtyRect.fill()
        guard let source = dataSource, source.rowCount > 0, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let first = max(0, Int(dirtyRect.minY / rowHeight))
        let last = min(source.rowCount - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let columns = source.columnCount
        let columnWidth = bounds.width / CGFloat(columns)
        for row in first...last {
            let y = CGFloat(row) * rowHeight
            for column in 0..<columns {
                let cell = source.cell(row: row, column: column)
                if cell.isFullWidth, column > 0 { continue }
                let width = cell.isFullWidth ? bounds.width : columnWidth
                let rect = NSRect(x: CGFloat(column) * columnWidth, y: y, width: width, height: rowHeight)
                guard rect.intersects(dirtyRect) else { continue }
                drawCell(cell, row: row, column: column, in: rect, source: source, context: context)
                if cell.isFullWidth { break }
            }
            if columns > 1 {
                ColorToken.borderSubtle.nsColor.setFill()
                NSRect(x: columnWidth - Border.hairline, y: y, width: Border.hairline, height: rowHeight).fill()
            }
        }
    }

    private func background(for kind: CodeCell.Kind) -> NSColor? {
        switch kind {
        case .added: ColorToken.diffAddBackground.nsColor
        case .deleted: ColorToken.diffDeleteBackground.nsColor
        case .filler: ColorToken.surfaceSunken.nsColor
        case .hunk, .gap, .file: ColorToken.surfaceSunken.nsColor
        case .conflict, .marker: ColorToken.conflictBackground.nsColor
        case .resolved: ColorToken.resolvedBackground.nsColor
        case .context: nil
        }
    }

    private func drawCell(
        _ cell: CodeCell, row: Int, column: Int, in rect: NSRect, source: any CodeLinesDataSource, context: CGContext
    ) {
        if let fill = background(for: cell.kind) {
            fill.setFill()
            rect.fill()
        }
        if source.isSelected(row: row, column: column) {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
            rect.fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
        }
        let gutter = gutterWidth
        if let drawLeadingGutter, leadingGutter > 0 {
            drawLeadingGutter(row, NSRect(x: rect.minX, y: rect.minY, width: leadingGutter, height: rect.height))
        }
        // Change bar at the gutter edge.
        if cell.kind == .added || cell.kind == .deleted {
            (cell.kind == .added ? ColorToken.diffAddMark : ColorToken.diffDeleteMark).nsColor.setFill()
            NSRect(x: rect.minX + gutter - Space.s3, y: rect.minY, width: 3, height: rect.height).fill()
        } else if cell.kind == .conflict || cell.kind == .marker || cell.kind == .resolved {
            (cell.kind == .resolved ? ColorToken.accentBase : ColorToken.conflictMark).nsColor.setFill()
            NSRect(x: rect.minX + gutter - Space.s3, y: rect.minY, width: 3, height: rect.height).fill()
        }
        let baseline = rect.minY + (rowHeight - (font.ascender - font.descender)) / 2 + font.ascender
        if !cell.isFullWidth {
            let digits = max(3, String(source.maxLineNumber).count)
            let numberWidth = CGFloat(digits) * characterWidth
            var x = rect.minX + leadingGutter + Space.s3
            let numbers: [Int?] =
                source.lineNumberColumns == 2 ? [cell.oldNumber, cell.newNumber] : [cell.oldNumber ?? cell.newNumber]
            for number in numbers {
                if let number {
                    let text = String(number)
                    let line = makeLine(text, color: ColorToken.textTertiary.nsColor)
                    drawLine(
                        line, at: NSPoint(x: x + numberWidth - CGFloat(text.count) * characterWidth, y: baseline),
                        context: context)
                }
                x += numberWidth + Space.s4
            }
        }
        // Text.
        let textX = cell.isFullWidth ? rect.minX + Space.s5 : rect.minX + gutter
        let key = CacheKey(row: row, column: column, generation: generation)
        let line: CTLine
        if let cached = cache[key] {
            line = cached
        } else {
            line = makeTextLine(cell, row: row, column: column, source: source)
            cache[key] = line
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                let drop = cacheOrder.prefix(Self.cacheLimit / 4)
                for old in drop { cache[old] = nil }
                cacheOrder.removeFirst(drop.count)
            }
        }
        // Search highlights under the text.
        let (ranges, current) = source.highlights(row: row, column: column)
        for range in ranges {
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            (range == current ? NSColor.findHighlightColor : NSColor.findHighlightColor.withAlphaComponent(0.35))
                .setFill()
            NSRect(x: textX + start, y: rect.minY + 1, width: max(2, end - start), height: rect.height - 2).fill()
        }
        context.saveGState()
        context.clip(to: rect)
        drawLine(line, at: NSPoint(x: textX, y: baseline), context: context)
        context.restoreGState()
    }

    private func drawLine(_ line: CTLine, at point: NSPoint, context: CGContext) {
        context.saveGState()
        // Flipped view: flip the text matrix so glyphs are upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func makeLine(_ text: String, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    /// Display text: tabs expanded to the next stop (whitespace marks optional); control characters as
    /// `␀`-style pictures so nothing invisible hides in a line.
    func displayText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count)
        var column = 0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t":
                let spaces = tabWidth - column % tabWidth
                out +=
                    showsWhitespace
                    ? "→" + String(repeating: " ", count: max(0, spaces - 1)) : String(repeating: " ", count: spaces)
                column += spaces
            case " ":
                out += showsWhitespace ? "·" : " "
                column += 1
            case "\u{0}"..."\u{8}", "\u{B}"..."\u{1F}", "\u{7F}":
                out.unicodeScalars.append(Unicode.Scalar(0x2400 + (scalar.value == 0x7F ? 0x21 : scalar.value)) ?? "?")
                column += 1
            default:
                out.unicodeScalars.append(scalar)
                column += 1
            }
        }
        return out
    }

    /// Maps a UTF-16 range in the original text to the display text (tabs widen). Identity without tabs.
    func displayRange(_ range: NSRange, in text: String) -> NSRange {
        guard text.contains("\t") else { return range }
        var mapping: [Int] = []
        var column = 0
        for unit in text.utf16 {
            mapping.append(column)
            column += unit == 9 ? tabWidth - column % tabWidth : 1
        }
        mapping.append(column)
        let start = mapping[min(range.location, mapping.count - 1)]
        let end = mapping[min(range.location + range.length, mapping.count - 1)]
        return NSRange(location: start, length: end - start)
    }

    private func makeTextLine(_ cell: CodeCell, row: Int, column: Int, source: any CodeLinesDataSource) -> CTLine {
        let fullLength = (cell.text as NSString).length
        var text = cell.text
        if fullLength > Self.maxRenderedCharacters {
            let cut = (cell.text as NSString).rangeOfComposedCharacterSequence(at: Self.maxRenderedCharacters).location
            text = (cell.text as NSString).substring(to: cut)
        }
        let display = displayText(text)
        let attributed = NSMutableAttributedString(
            string: display,
            attributes: [
                .font: font,
                .foregroundColor: cell.isFullWidth ? ColorToken.textSecondary.nsColor : ColorToken.textPrimary.nsColor,
            ])
        let length = (display as NSString).length
        for (range, color) in source.syntax(row: row, column: column)
        where NSMaxRange(range) <= (text as NSString).length {
            let mapped = displayRange(range, in: text)
            if NSMaxRange(mapped) <= length { attributed.addAttribute(.foregroundColor, value: color, range: mapped) }
        }
        let emphasisColor = (cell.kind == .added ? ColorToken.diffAddMark : ColorToken.diffDeleteMark).nsColor
            .withAlphaComponent(0.28)
        for range in source.emphasis(row: row, column: column) where NSMaxRange(range) <= (text as NSString).length {
            let mapped = displayRange(range, in: text)
            if NSMaxRange(mapped) <= length {
                attributed.addAttribute(.backgroundColor, value: emphasisColor, range: mapped)
            }
        }
        if showsWhitespace {
            for (index, unit) in display.utf16.enumerated() where unit == 0xB7 || unit == 0x2192 {
                attributed.addAttribute(
                    .foregroundColor, value: ColorToken.textDisabled.nsColor, range: NSRange(location: index, length: 1)
                )
            }
        }
        if text.utf16.count < fullLength {
            let hidden = fullLength - (text as NSString).length
            attributed.append(
                NSAttributedString(
                    string: "  … +\(hidden.formatted()) characters not shown",
                    attributes: [.font: TypeToken.caption.nsFont, .foregroundColor: ColorToken.textTertiary.nsColor]))
        }
        if let note = cell.note {
            attributed.append(
                NSAttributedString(
                    string: "  " + note,
                    attributes: [.font: TypeToken.caption.nsFont, .foregroundColor: ColorToken.textTertiary.nsColor]))
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    // MARK: Input

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(at: point) else { return }
        if leadingGutter > 0, point.x < leadingGutter, let onGutterClick {
            onGutterClick(row)
            return
        }
        delegate?.codeLines(self, clickedRow: row, column: column(at: point), modifiers: event.modifierFlags)
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        guard let row = row(at: point) else { return }
        delegate?.codeLines(self, draggedTo: row, column: column(at: point))
    }

    public override func keyDown(with event: NSEvent) {
        if delegate?.codeLines(self, keyDown: event) == true { return }
        super.keyDown(with: event)
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = delegate?.codeLinesCopyText(self) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if toolTipProvider != nil {
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateText()
    }

    // MARK: Accessibility (visible rows only)

    public override func accessibilityChildren() -> [Any]? {
        guard let source = dataSource, source.rowCount > 0, let visible = enclosingScrollView?.documentVisibleRect
        else {
            return []
        }
        let first = max(0, Int(visible.minY / rowHeight))
        let last = min(source.rowCount - 1, Int(visible.maxY / rowHeight))
        guard first <= last else { return [] }
        var result: [NSAccessibilityElement] = []
        for row in first...last {
            let element = accessibilityRows[row] ?? NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(delegate?.codeLines(self, accessibilityLabelFor: row) ?? "")
            element.setAccessibilityFrameInParentSpace(rowRect(row))
            element.setAccessibilitySelected(source.isSelected(row: row, column: 0))
            accessibilityRows[row] = element
            result.append(element)
        }
        if accessibilityRows.count > 400 {
            accessibilityRows = accessibilityRows.filter { (first...last).contains($0.key) }
        }
        return result
    }
}

extension CodeLinesView: NSViewToolTipOwner {
    public func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let row = row(at: point) else { return "" }
        return toolTipProvider?(row) ?? ""
    }
}
