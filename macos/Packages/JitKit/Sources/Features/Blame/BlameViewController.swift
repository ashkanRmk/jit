import AppKit
import DesignSystem
import GitCore
import Observation
import Services
import SwiftUI

/// Blame state (design §3.5): the file's lines, which commit each comes from (filled as Git streams), and
/// the options. Opened over the graph area; Esc closes.
@MainActor @Observable
public final class BlameModel {
    public let session: RepositorySession
    public private(set) var path: String?
    public private(set) var revision: ObjectID?
    public var ignoreWhitespace = false { didSet { if ignoreWhitespace != oldValue { restart() } } }
    public var detectMoves = false { didSet { if detectMoves != oldValue { restart() } } }
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Blocks received so far (for the "n of m lines" progress).
    public private(set) var attributedLines = 0
    public var isOpen: Bool { path != nil }

    /// File bytes and line ranges (strings only for visible rows).
    @ObservationIgnored private(set) var content: [UInt8] = []
    @ObservationIgnored private(set) var lineRanges: [Range<Int>] = []
    /// Commit index per line (`-1` until Git reports it).
    @ObservationIgnored private(set) var owners: [Int32] = []
    @ObservationIgnored private(set) var commits: [BlameCommit] = []
    @ObservationIgnored private var commitIndex: [String: Int32] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var handle: RepositoryHandle?
    @ObservationIgnored var onRowsChanged: (() -> Void)?
    @ObservationIgnored var onReload: (() -> Void)?
    /// Selects a commit in the graph.
    @ObservationIgnored public var revealCommit: (ObjectID) -> Void = { _ in }
    @ObservationIgnored private var newestTime: Int64 = 0
    @ObservationIgnored private var oldestTime: Int64 = 0

    public init(session: RepositorySession) {
        self.session = session
        observeLifecycle()
    }

    /// Inactive tabs drop the blamed text and attribution; blame restarts when the tab shows again.
    private func observeLifecycle() {
        withObservationTracking {
            _ = session.lifecycle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.session.lifecycle {
                case .inactive, .suspended, .closed:
                    if !self.content.isEmpty {
                        self.task?.cancel()
                        self.content = []
                        self.lineRanges = []
                        self.owners = []
                        self.commits = []
                        self.onReload?()
                    }
                case .active:
                    if self.isOpen, self.content.isEmpty { self.restart() }
                default:
                    break
                }
                self.observeLifecycle()
            }
        }
    }

    public func open(path: String, revision: ObjectID?) {
        self.path = path
        self.revision = revision
        restart()
    }

    public func close() {
        task?.cancel()
        path = nil
        content = []
        lineRanges = []
        owners = []
        commits = []
        onReload?()
    }

    private func restart() {
        task?.cancel()
        guard let path, let handle else { return }
        isLoading = true
        error = nil
        attributedLines = 0
        commits = []
        commitIndex = [:]
        newestTime = 0
        oldestTime = .max
        let options = BlameOptions(ignoreWhitespace: ignoreWhitespace, detectMoves: detectMoves, revision: revision)
        let revision = self.revision
        task = Task { [weak self] in
            do {
                let bytes = try await handle.blameContent(path, revision: revision)
                guard let self, !Task.isCancelled else { return }
                self.setContent(bytes)
                var batch = 0
                for try await event in handle.blame(path, options: options) {
                    guard !Task.isCancelled else { return }
                    self.apply(event)
                    batch += 1
                    // Lines appear with blank gutters that fill as data arrives; redraw in batches.
                    if batch % 64 == 0 { self.onRowsChanged?() }
                }
                self.isLoading = false
                self.onRowsChanged?()
            } catch is CancellationError {
                return
            } catch let error as GitCoreError {
                if case .cancelled = error { return }
                self?.isLoading = false
                self?.error = error.summary
            } catch {
                self?.isLoading = false
                self?.error = error.localizedDescription
            }
        }
    }

    private func setContent(_ bytes: [UInt8]) {
        content = bytes
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            var end = index
            if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            ranges.append(start..<end)
            start = index + 1
        }
        if start < bytes.count { ranges.append(start..<bytes.count) }
        lineRanges = ranges
        owners = [Int32](repeating: -1, count: ranges.count)
        onReload?()
    }

    private func apply(_ event: BlameEvent) {
        switch event {
        case .commit(let commit):
            commitIndex[commit.id] = Int32(commits.count)
            commits.append(commit)
            if !commit.isUncommitted {
                newestTime = max(newestTime, commit.authorTime)
                oldestTime = min(oldestTime, commit.authorTime)
            }
        case .block(let block):
            guard let index = commitIndex[block.commitID] else { return }
            for line in (block.finalLine - 1)..<(block.finalLine - 1 + block.count) where owners.indices.contains(line)
            {
                owners[line] = index
            }
            attributedLines += block.count
        }
    }

    // MARK: Rows

    var lineCount: Int { lineRanges.count }

    func text(_ line: Int) -> String { String(decoding: content[lineRanges[line]], as: UTF8.self) }

    func commit(atLine line: Int) -> BlameCommit? {
        guard owners.indices.contains(line), owners[line] >= 0 else { return nil }
        return commits[Int(owners[line])]
    }

    /// The first line of a run from the same commit shows the block's details.
    func startsBlock(_ line: Int) -> Bool {
        line == 0 || owners[line] != owners[line - 1] || owners[line] < 0
    }

    /// 0 (oldest) … 1 (newest), for the gutter's luminance ramp.
    func age(_ commit: BlameCommit) -> Double {
        if commit.isUncommitted { return 1 }
        guard newestTime > oldestTime else { return 1 }
        return Double(commit.authorTime - oldestTime) / Double(newestTime - oldestTime)
    }

    public var title: String { path.map { "Blame — \($0)" } ?? "" }
    public var subtitle: String {
        let base = revision.map { "at \($0.hex(.sha1, length: 7))" } ?? "Working copy"
        if isLoading { return "\(base) · \(attributedLines) of \(lineCount) lines" }
        return base
    }
}

/// Rows of the blamed file for `CodeLinesView`.
@MainActor final class BlameSource: CodeLinesDataSource {
    let model: BlameModel
    init(model: BlameModel) { self.model = model }

    var rowCount: Int { model.lineCount }
    var columnCount: Int { 1 }
    var maxColumnCharacters: Int { model.lineRanges.map(\.count).max() ?? 0 }
    var maxLineNumber: Int { model.lineCount }
    var lineNumberColumns: Int { 1 }

    func cell(row: Int, column: Int) -> CodeCell {
        CodeCell(kind: .context, newNumber: row + 1, text: model.text(row))
    }

    func isSelected(row: Int, column: Int) -> Bool { false }
    func highlights(row: Int, column: Int) -> (ranges: [NSRange], current: NSRange?) { ([], nil) }
}

/// Blame view (design §3.5): code with a 240 pt gutter grouping consecutive lines from one commit (initials,
/// author, relative date, subject), an age ramp on the gutter edge, hover for SHA and full subject, and a
/// click that selects the commit in the graph.
@MainActor
public final class BlameViewController: NSViewController {
    public let model: BlameModel
    let codeView = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    private let scrollView = NSScrollView()
    private lazy var source = BlameSource(model: model)
    private static let gutterWidth: CGFloat = 240

    public init(model: BlameModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: DiffChromeView.height, left: 0, bottom: 0, right: 0)
        scrollView.documentView = codeView
        root.addSubview(scrollView)
        codeView.leadingGutter = Self.gutterWidth
        codeView.drawLeadingGutter = { [weak self] row, rect in self?.drawGutter(row, rect) }
        codeView.onGutterClick = { [weak self] row in
            guard let self, let commit = self.model.commit(atLine: row), !commit.isUncommitted,
                let oid = ObjectID(hex: commit.id)
            else { return }
            self.model.revealCommit(oid)
        }
        codeView.toolTipProvider = { [weak self] row in
            guard let commit = self?.model.commit(atLine: row) else { return nil }
            if commit.isUncommitted { return "Not committed yet" }
            return
                "\(commit.id)\n\(commit.author) \(commit.authorMail)\n\(Self.date(commit.authorTime))\n\n\(commit.summary)"
        }
        let chrome = NSHostingView(rootView: BlameChrome(model: model))
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.sizingOptions = [.intrinsicContentSize]
        chrome.safeAreaRegions = []
        chrome.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chrome.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(chrome)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        view = root
        model.onReload = { [weak self] in
            guard let self else { return }
            self.codeView.dataSource = self.model.isOpen ? self.source : nil
        }
        model.onRowsChanged = { [weak self] in self?.codeView.refreshRows() }
    }

    public override func cancelOperation(_ sender: Any?) { model.close() }

    static func date(_ time: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ time: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(time)).formatted(.relative(presentation: .named))
    }

    private func drawGutter(_ row: Int, _ rect: NSRect) {
        ColorToken.surfaceSunken.nsColor.setFill()
        rect.fill()
        guard let commit = model.commit(atLine: row) else { return }
        // Age ramp: newest brightest, on the gutter's trailing edge.
        let age = model.age(commit)
        ColorToken.accentBase.nsColor.withAlphaComponent(0.15 + 0.75 * age).setFill()
        NSRect(x: rect.maxX - 4, y: rect.minY, width: 3, height: rect.height).fill()
        guard model.startsBlock(row) else { return }
        ColorToken.borderSubtle.nsColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: Border.hairline).fill()
        let font = TypeToken.caption.nsFont
        let baseline = rect.minY + (rect.height - font.pointSize) / 2 - 1
        if commit.isUncommitted {
            ("Not committed yet" as NSString).draw(
                at: NSPoint(x: rect.minX + Space.s4, y: baseline),
                withAttributes: [.font: font, .foregroundColor: ColorToken.textTertiary.nsColor])
            return
        }
        // Initials avatar.
        let diameter = rect.height - 4
        let circle = NSRect(x: rect.minX + Space.s3, y: rect.minY + 2, width: diameter, height: diameter)
        var hash = StableHash()
        hash.combine(commit.authorMail)
        LaneColor.allCases[Int(hash.value % UInt64(LaneColor.allCases.count))].nsColor.setFill()
        NSBezierPath(ovalIn: circle).fill()
        let initials = commit.author.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        let initialsFont = TypeToken.micro.nsFont
        let size = (initials as NSString).size(withAttributes: [.font: initialsFont])
        (initials as NSString).draw(
            at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
            withAttributes: [.font: initialsFont, .foregroundColor: ColorToken.accentOnAccent.nsColor])
        let text = "\(commit.author) · \(Self.relative(commit.authorTime)) · \(commit.summary)"
        let textRect = NSRect(
            x: circle.maxX + Space.s3, y: baseline, width: rect.width - diameter - Space.s8, height: rect.height)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: ColorToken.textSecondary.nsColor, .paragraphStyle: style])
    }
}

/// Glass chrome over the blame body: title, options (-w, -M), close.
struct BlameChrome: View {
    @Bindable var model: BlameModel

    var body: some View {
        GlassControlGroup(spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(DisplayText.sanitize(model.title))
                    .typeStyle(.callout)
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.subtitle)
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textSecondary))
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s2)
            .jitGlass(in: Capsule(), interactive: false)
            Spacer(minLength: Space.s4)
            if let error = model.error {
                Text(error)
                    .typeStyle(.caption)
                    .foregroundStyle(.token(.statusDanger))
                    .lineLimit(2)
            }
            Menu {
                Toggle("Ignore Whitespace (-w)", isOn: $model.ignoreWhitespace)
                Toggle("Detect Moved Lines (-M)", isOn: $model.detectMoves)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Blame Options (blame.ignoreRevsFile is applied when configured)")
            .accessibilityLabel("Blame options")
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .help("Close Blame (Esc)")
            .accessibilityLabel("Close blame")
        }
        .padding(.horizontal, Space.s5)
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s2)
        .ignoresSafeArea()
    }
}
