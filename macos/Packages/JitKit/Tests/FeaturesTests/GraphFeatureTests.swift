import DesignSystem
import Foundation
import GitCore
import Testing

@testable import Features

/// A 40-hex-digit object id made of one repeated digit (no force unwrap: swift-format's NeverForceUnwrap).
func testObjectID(_ digit: Character) -> ObjectID {
    guard let id = ObjectID(hex: String(repeating: digit, count: 40)) else { preconditionFailure("invalid hex digit") }
    return id
}

@Suite struct NavigatorTreeBuilderTests {
    static func ref(_ name: String, head: Bool = false, ahead: Int = 0, behind: Int = 0) -> GitRef {
        let kind: GitRef.Kind =
            name.hasPrefix("refs/heads/") ? .local : name.hasPrefix("refs/remotes/") ? .remote : .tag
        let oid = testObjectID("a")
        return GitRef(fullName: name, kind: kind, object: oid, commit: oid, ahead: ahead, behind: behind, isHead: head)
    }

    static func snapshot(_ refs: [GitRef], head: HeadState = .unborn(branch: "main")) -> RefSnapshot {
        RefSnapshot(head: head, refs: refs, format: .sha1, revision: 1)
    }

    func titles(_ nodes: [NavigatorNode]) -> [String] { nodes.map(\.title) }

    @Test func groupsByHierarchyAndCollapsesSingleChildFolders() {
        let refs = Self.snapshot(
            [
                Self.ref("refs/heads/feature/ui/tabs"), Self.ref("refs/heads/main", head: true),
                Self.ref("refs/heads/fix/a"), Self.ref("refs/heads/fix/b"),
            ], head: .branch(name: "main", commit: .zero))
        let local = NavigatorTreeBuilder.build(refs)[0]
        #expect(local.title == "Local")
        #expect(titles(local.children) == ["main", "feature/ui", "fix"])
        #expect(titles(local.children[1].children) == ["tabs"])
        #expect(titles(local.children[2].children) == ["a", "b"])
        #expect(local.refCount == 4)
    }

    @Test func naturalSortCurrentFirst() {
        let refs = Self.snapshot(
            [
                Self.ref("refs/heads/f-10"), Self.ref("refs/heads/f-2"), Self.ref("refs/heads/zeta", head: true),
                Self.ref("refs/heads/F-1"),
            ], head: .branch(name: "zeta", commit: .zero))
        let local = NavigatorTreeBuilder.build(refs)[0]
        #expect(titles(local.children) == ["zeta", "F-1", "f-2", "f-10"])
    }

    @Test func remotesGroupedPerRemoteAndTagsNote() {
        let refs = Self.snapshot([
            Self.ref("refs/heads/main"), Self.ref("refs/remotes/origin/main"), Self.ref("refs/remotes/upstream/dev"),
        ])
        let sections = NavigatorTreeBuilder.build(refs)
        #expect(titles(sections) == ["Local", "Remote", "Tags"])
        #expect(titles(sections[1].children) == ["origin", "upstream"])
        #expect(titles(sections[1].children[0].children) == ["main"])
        #expect(sections[2].children.first?.kind == .note("No tags"))
    }

    @Test func noRemotesHidesSectionAndUnbornShowsNote() {
        let sections = NavigatorTreeBuilder.build(Self.snapshot([]))
        #expect(titles(sections) == ["Local", "Tags"])
        #expect(sections[0].children.first?.kind == .note("main — no commits"))
    }

    @Test func filterKeepsMatchesAndExpandsTheirFolders() {
        let refs = Self.snapshot([Self.ref("refs/heads/feature/ui/tabs"), Self.ref("refs/heads/main")])
        let sections = NavigatorTreeBuilder.build(refs, filter: "ftabs")
        #expect(sections.count == 1)
        #expect(sections[0].refCount == 1)
        let ids = sections[0].expandableIDs { FuzzyMatch.matches("ftabs", $0.shortName) }
        #expect(ids.contains("section/Local"))
        #expect(ids.contains("section/Local/feature/ui"))
    }

    @Test func navigator10kBranchesBuildUnder50ms() {
        var refs: [GitRef] = []
        for index in 0..<10_000 {
            refs.append(Self.ref("refs/heads/team\(index % 50)/topic\(index % 7)/feature-\(index)"))
        }
        let snapshot = Self.snapshot(refs)
        let started = ContinuousClock.now
        let sections = NavigatorTreeBuilder.build(snapshot)
        let elapsed = ContinuousClock.now - started
        print("navigator 10k build: \(elapsed)")
        #expect(sections[0].refCount == 10_000)
        #if DEBUG
            #expect(elapsed < .milliseconds(750))
        #else
            #expect(elapsed < .milliseconds(50))
        #endif
    }
}

@Suite struct NavigatorFilterTests {
    @Test func fuzzySubsequence() {
        #expect(FuzzyMatch.matches("ftb", "feature/tabs"))
        #expect(FuzzyMatch.matches("FEAT", "feature/x"))
        #expect(!FuzzyMatch.matches("bft", "feature/tabs"))
        #expect(FuzzyMatch.matches("", "anything"))
    }
}

@Suite struct DisplayTextTests {
    @Test func controlCharactersBecomeVisible() {
        #expect(DisplayText.sanitize("a\u{1B}[31mb") == "a\u{241B}[31mb")
        #expect(DisplayText.sanitize("tab\there") == "tab\u{2409}here")
    }

    @Test func bidiOverridesNeutralised() {
        let sanitized = DisplayText.sanitize("evil\u{202E}txt.exe")
        #expect(!sanitized.unicodeScalars.contains { $0.value == 0x202E })
        #expect(sanitized.hasPrefix("\u{2068}"))
        #expect(DisplayText.sanitize("שלום").hasPrefix("\u{2068}"))
        #expect(DisplayText.sanitize("plain") == "plain")
    }
}

@Suite struct LaneGeometryTests {
    @Test func laneXAndCompression() {
        let metrics = GraphMetrics.comfortable
        #expect(metrics.laneX(0) == metrics.leadingInset + metrics.laneSpacing / 2)
        #expect(metrics.laneX(1) - metrics.laneX(0) == metrics.laneSpacing)
        let last = metrics.laneX(metrics.maxVisibleLanes - 1)
        #expect(metrics.laneX(metrics.maxVisibleLanes) - last < metrics.laneSpacing)
        #expect(
            metrics.laneX(metrics.maxVisibleLanes + 1) - metrics.laneX(metrics.maxVisibleLanes)
                == metrics.compressedLaneSpacing)
        #expect(metrics.columnWidth(lanes: 2) == metrics.leadingInset * 2 + metrics.laneSpacing * 2)
    }

    @Test func pixelSnappingKeepsLinesCrisp() {
        // 1.5 pt at 2× = 3 px (odd): centre on a half pixel.
        let x2 = GraphMetrics.snap(20.3, width: 1.5, scale: 2)
        #expect((x2 * 2).truncatingRemainder(dividingBy: 1) == 0.5)
        // 1 pt at 1× (odd): half pixel; 2 pt at 1× (even): whole pixel.
        #expect(GraphMetrics.snap(20.3, width: 1, scale: 1) == 20.5)
        #expect(GraphMetrics.snap(20.3, width: 2, scale: 1) == 20)
    }
}

@Suite struct RefLabelTests {
    @MainActor @Test func localAndUpstreamCombineCurrentFirst() {
        let commit = testObjectID("b")
        let refs = RefSnapshot(
            head: .branch(name: "main", commit: commit),
            refs: [
                GitRef(fullName: "refs/heads/aaa", kind: .local, object: commit, commit: commit),
                GitRef(
                    fullName: "refs/heads/main", kind: .local, object: commit, commit: commit, upstream: "origin/main",
                    isHead: true),
                GitRef(fullName: "refs/remotes/origin/main", kind: .remote, object: commit, commit: commit),
                GitRef(fullName: "refs/remotes/origin/other", kind: .remote, object: commit, commit: commit),
                GitRef(fullName: "refs/tags/v1", kind: .tag, object: commit, commit: commit),
            ], format: .sha1, revision: 1)
        let labels = GraphRowCache.labels(for: refs)[commit] ?? []
        #expect(labels.map(\.text) == ["main", "aaa", "origin/other", "v1"])
        #expect(labels.first?.kind == .localWithUpstream(remote: "origin", isCurrent: true))
    }

    @MainActor @Test func detachedHeadPill() {
        let commit = testObjectID("c")
        let refs = RefSnapshot(head: .detached(commit: commit), refs: [], format: .sha1, revision: 2)
        #expect(GraphRowCache.labels(for: refs)[commit]?.first?.kind == .detachedHead)
    }
}

@Suite struct MessageReflowTests {
    @Test func joinsHardWrappedParagraphsKeepsStructure() {
        let body =
            "Some of the tests create\nmany refs and then\nverify them.\n\n* topic:\n  t5551: use reftables\n- item one\n\nSigned-off-by: A <a@b>\nAcked-by: B <b@c>"
        #expect(
            MessageReflow.reflow(body)
                == "Some of the tests create many refs and then verify them.\n\n* topic:\n  t5551: use reftables\n- item one\n\nSigned-off-by: A <a@b>\nAcked-by: B <b@c>"
        )
    }
}

@Suite struct DisplayTextMoreTests {
    @Test func keepNewlinesAndC1() {
        #expect(DisplayText.sanitize("a\nb", keepNewlines: true) == "a\nb")
        #expect(DisplayText.sanitize("a\nb") == "a\u{240A}b")
        #expect(DisplayText.sanitize("x\u{9B}y") == "x\u{FFFD}y")
    }
}
