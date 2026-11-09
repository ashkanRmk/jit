import Foundation
import Testing

/// P6.7 Liquid Glass audit (ADR-0006): glass reaches feature code only through the DesignSystem helpers, and
/// only in chrome surfaces (toolbar items, floating bars/capsules over content, sheets' action rows, the
/// palette). Content views — graph rows, diff lines, file lists, navigator, inspector body — never use it.
@Suite struct GlassPolicyTests {
    /// Files allowed to place glass, with the chrome surface each one owns (visual-review.md inventory).
    static let allowlist: [String: String] = [
        "TabStrip.swift": "toolbar tab strip (one GlassEffectContainer)",
        "ProfileViews.swift": "toolbar profile capsule and switcher popover actions",
        "CommandBarView.swift": "floating command bar over the graph",
        "GraphBar.swift": "graph command bar / search capsule",
        "DiffViewController.swift": "floating diff chrome bar and selection capsule",
        "BlameViewController.swift": "floating blame bar",
        "ResolverViewController.swift": "resolver floating toolbar and bottom action bar",
        "CommitComposer.swift": "composer bottom action bar",
        "OperationBanner.swift": "floating operation banner",
        "NewTabView.swift": "new-tab primary and secondary actions",
        "CommandPaletteView.swift": "command palette panel (one container)",
    ]

    static let glassCalls = [
        "jitGlass(", "primaryGlassButton(", "secondaryGlassButton(", "tintedGlassBar(", "glassTab(",
        "GlassControlGroup", "FloatingGlassCapsule", "GlassTabStrip", ".glassEffect(", "NSGlassEffectView",
        "buttonStyle(.glass", "NSVisualEffectView", "CIFilter", ".blur(radius:",
    ]

    @Test func glassOnlyInChromeFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Features")
        var findings: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/Gallery/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let uses = Self.glassCalls.filter { text.contains($0) }
            if !uses.isEmpty, Self.allowlist[url.lastPathComponent] == nil {
                findings.append("\(url.lastPathComponent): \(uses)")
            }
            // Raw glass APIs and custom blur never appear in Features, allowlisted or not.
            for raw in [".glassEffect(", "NSGlassEffectView", "buttonStyle(.glass", "NSVisualEffectView", "CIFilter"]
            where text.contains(raw) {
                findings.append("\(url.lastPathComponent): raw \(raw)")
            }
        }
        #expect(findings.isEmpty, "\(findings)")
    }
}
