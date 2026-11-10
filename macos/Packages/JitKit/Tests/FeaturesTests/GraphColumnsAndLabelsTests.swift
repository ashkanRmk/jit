import AppKit
import DesignSystem
import Foundation
import GitCore
import Services
import Testing

@testable import Features

/// 0.0.2: column order / visibility / widths, ref label glyphs and tooltips, file path layout.
@Suite struct GraphColumnLayoutTests {
    @Test func defaultsShowEveryColumnInOrder() {
        let layout = GraphColumnLayout()
        #expect(layout.order == [.refs, .graph, .subject, .author, .date, .sha])
        #expect(layout.hidden.isEmpty)
        #expect(layout.width(.author) == 150)
    }

    @Test func roundTripsOrderHiddenAndWidths() {
        var layout = GraphColumnLayout()
        layout.order = [.subject, .refs, .graph, .date, .author, .sha]
        layout.setHidden(.sha, true)
        layout.widths[.author] = 210
        #expect(GraphColumnLayout(json: layout.json) == layout)
    }

    @Test func readsTheWidthOnlyFormatSavedBefore002() {
        let layout = GraphColumnLayout(json: .object(["author": .number(180), "refs": .number(20)]))
        #expect(layout.width(.author) == 180)
        // Never below the column's minimum.
        #expect(layout.width(.refs) == GraphColumnLayout.Column.refs.minWidth)
        #expect(layout.order == GraphColumnLayout.Column.allCases)
    }

    @Test func unknownAndMissingColumnsAreRepaired() {
        let layout = GraphColumnLayout(
            json: .object(["order": .array([.string("sha"), .string("bogus"), .string("sha"), .string("subject")])]))
        #expect(Set(layout.order) == Set(GraphColumnLayout.Column.allCases))
        #expect(layout.order.count == GraphColumnLayout.Column.allCases.count)
        #expect(layout.order.firstIndex(of: .sha) ?? 9 < layout.order.firstIndex(of: .subject) ?? 0)
    }

    @Test func theMessageColumnCannotBeHidden() {
        var layout = GraphColumnLayout()
        layout.setHidden(.subject, true)
        #expect(layout.hidden.isEmpty)
        let restored = GraphColumnLayout(json: .object(["hidden": .array([.string("subject"), .string("date")])]))
        #expect(restored.hidden == [.date])
    }

    @Test func wideLayoutKeepsPreferredWidthsAndGivesTheRestToTheMessage() {
        let layout = GraphColumnLayout()
        let fitted = layout.fitted(available: 1200, fixed: [.graph: 80])
        #expect(fitted.autoHidden.isEmpty)
        #expect(fitted.widths[.author] == 150)
        let rest: CGFloat = 644  // 1200 − 150 − 80 − 150 − 104 − 72
        #expect(fitted.widths[.subject] == rest)
    }

    @Test func narrowLayoutHidesTheShaThenNarrowsAuthorDateAndBranch() {
        let layout = GraphColumnLayout()
        let fitted = layout.fitted(available: 560, fixed: [.graph: 80])
        #expect(fitted.autoHidden == [.sha])
        #expect(fitted.widths[.sha] == nil)
        #expect(fitted.widths[.author] == GraphColumnLayout.Column.author.minWidth)
        // The branch column is the last to give up width.
        #expect(fitted.widths[.refs] ?? 0 > GraphColumnLayout.Column.refs.minWidth)
        #expect(fitted.widths.values.reduce(0, +) <= 560)
    }

    @Test func hiddenColumnsTakeNoWidth() {
        var layout = GraphColumnLayout()
        layout.setHidden(.author, true)
        layout.setHidden(.date, true)
        let fitted = layout.fitted(available: 800, fixed: [.graph: 80])
        #expect(fitted.widths[.author] == nil)
        let rest: CGFloat = 498  // 800 − 150 − 80 − 72
        #expect(fitted.widths[.subject] == rest)
    }
}

@Suite struct RefLabelGlyphTests {
    @MainActor static func style() throws -> GraphStyle {
        let style = GraphStyle(density: .comfortable)
        _ = style.update(appearance: try #require(NSAppearance(named: .aqua)))
        return style
    }

    @MainActor @Test func upstreamNameIsKeptForTheCloudTooltip() {
        let commit = testObjectID("d")
        let refs = RefSnapshot(
            head: .branch(name: "main", commit: commit),
            refs: [
                GitRef(
                    fullName: "refs/heads/main", kind: .local, object: commit, commit: commit, upstream: "origin/main",
                    isHead: true),
                GitRef(fullName: "refs/remotes/origin/main", kind: .remote, object: commit, commit: commit),
            ], format: .sha1, revision: 7)
        #expect(GraphRowCache.labels(for: refs)[commit]?.first?.upstream == "origin/main")
    }

    @MainActor @Test func localAndRemoteBranchHasAComputerAndACloudRegion() throws {
        let painter = PillPainter(style: try Self.style(), slot: 1)
        let label = RefLabel(
            kind: .localWithUpstream(remote: "origin", isCurrent: false), text: "main", fullName: "refs/heads/main",
            upstream: "origin/main")
        let width = painter.width(label)
        let regions = painter.regions(label, at: 10, mid: 16, width: width)
        #expect(regions.map(\.toolTip) == ["Local branch main", "origin/main", "main — local and origin/main"])
        // Regions tile the pill left to right without overlapping.
        #expect(regions.first?.rect.minX == 10)
        #expect(regions.last?.rect.maxX == 10 + width)
        for (a, b) in zip(regions, regions.dropFirst()) { #expect(a.rect.maxX <= b.rect.minX + 0.01) }
    }

    @MainActor @Test func remoteOnlyBranchDropsTheRemotePrefixFromThePill() throws {
        let painter = PillPainter(style: try Self.style(), slot: 0)
        let remote = RefLabel(kind: .remote, text: "origin/feature/x", fullName: "refs/remotes/origin/feature/x")
        let plain = RefLabel(kind: .remote, text: "upstream-fork/feature/x", fullName: "x")
        // "origin/" is not drawn: the cloud glyph says it is remote, the tooltip says which remote.
        #expect(painter.width(remote) == painter.width(plain))
        #expect(
            painter.regions(remote, at: 0, mid: 10, width: painter.width(remote)).first?.toolTip == "origin/feature/x")
    }

    @MainActor @Test func hoverViewShowsEveryLabelInFull() throws {
        let style = try Self.style()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        let labels = [
            RefLabel(kind: .current, text: "main", fullName: "refs/heads/main"),
            RefLabel(kind: .local, text: "feature/a-rather-long-branch-name", fullName: "refs/heads/feature/a"),
            RefLabel(kind: .tag, text: "v1.0.0", fullName: "refs/tags/v1.0.0"),
        ]
        style.reduceMotion = true
        let hover = RefsHoverView()
        let cell = NSRect(x: 0, y: 32, width: 96, height: 32)
        hover.show(
            row: 1, labels: labels, slot: 0, isSelected: false, style: style, cellFrame: cell, maxWidth: 900, in: table)
        #expect(hover.row == 1)
        #expect(!hover.isHidden)
        #expect(hover.frame.width == RefsHoverView.naturalWidth(labels, style: style, slot: 0))
        #expect(hover.frame.width > cell.width)
        #expect(hover.pillFrames.map(\.0) == labels)
        let painter = PillPainter(style: style, slot: 0)
        for (label, frame) in hover.pillFrames { #expect(frame.width == painter.width(label)) }
        let tag = hover.pillFrames[2].1
        #expect(hover.label(at: NSPoint(x: tag.midX, y: tag.midY)) == labels[2])
        hover.hide(animated: false)
        #expect(hover.isHidden)
    }

    @MainActor @Test func hoverViewNeverGrowsPastTheTable() throws {
        let style = try Self.style()
        style.reduceMotion = true
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let long = RefLabel(kind: .local, text: String(repeating: "very-long-", count: 12), fullName: "x")
        let hover = RefsHoverView()
        hover.show(
            row: 0, labels: [long, long], slot: 0, isSelected: true, style: style,
            cellFrame: NSRect(x: 0, y: 0, width: 96, height: 32), maxWidth: 300, in: table)
        #expect(hover.frame.width == 300)
        #expect(hover.pillFrames.allSatisfy { $0.1.maxX <= 300 })
    }
}

@Suite struct FilePathLayoutTests {
    @Test func everythingFitsUntouched() {
        let widths = FilePathLayout.widths(available: 300, folders: 120, name: 100)
        #expect(widths.folders == 120)
        #expect(widths.name == 100)
    }

    @Test func foldersShortenAndTheNameStaysWhole() {
        let widths = FilePathLayout.widths(available: 200, folders: 160, name: 120)
        #expect(widths.name == 120)
        #expect(widths.folders == 80)
    }

    @Test func foldersDisappearWhenOnlyASliverIsLeft() {
        let widths = FilePathLayout.widths(available: 140, folders: 160, name: 120)
        #expect(widths.folders == 0)
        #expect(widths.name == 120)
    }

    @Test func aNameWiderThanTheRowTakesTheWholeRow() {
        let widths = FilePathLayout.widths(available: 90, folders: 160, name: 120)
        #expect(widths.folders == 0)
        #expect(widths.name == 90)
    }

    @Test func shortFoldersThatFitAreKept() {
        // "a/" is narrower than the minimum, but it fits whole: nothing to hide.
        let widths = FilePathLayout.widths(available: 200, folders: 14, name: 120)
        #expect(widths.folders == 14)
    }
}
