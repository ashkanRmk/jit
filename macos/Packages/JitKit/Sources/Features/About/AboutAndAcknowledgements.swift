import AppKit
import DesignSystem
import SwiftUI

/// What Jit tells the user about itself and the third-party code it ships (Phase 7 design §3.4).
/// Everything here is read from the app bundle; nothing is fetched.
public struct ReleaseInfo: Sendable {
    public let version: String
    public let build: String
    /// Short commit the release was built from (`JitSourceCommit`, added by scripts/release/01-build-app.sh).
    public let commit: String?
    public let copyright: String
    /// The bundled Git runtime (`Contents/Resources/git`), when present.
    public let bundledGit: BundledGit?

    public struct BundledGit: Sendable {
        public let version: String
        public let license: String
        public let source: String
    }

    public init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "–"
        build = info["CFBundleVersion"] as? String ?? "–"
        commit = info["JitSourceCommit"] as? String
        copyright = info["NSHumanReadableCopyright"] as? String ?? ""
        if let git = bundle.resourceURL?.appendingPathComponent("git"),
            let version = try? String(contentsOf: git.appendingPathComponent("VERSION"), encoding: .utf8),
            let license = try? String(contentsOf: git.appendingPathComponent("LICENSE"), encoding: .utf8),
            let source = try? String(contentsOf: git.appendingPathComponent("SOURCE.txt"), encoding: .utf8)
        {
            bundledGit = BundledGit(
                version: version.trimmingCharacters(in: .whitespacesAndNewlines), license: license, source: source)
        } else {
            bundledGit = nil
        }
    }

    /// "1.0.0 (1, a1b2c3d)" — the build line of the About panel.
    public var buildLine: String {
        [build, commit].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum AboutPanel {
    /// The standard macOS About panel with the build, commit and a pointer to the acknowledgements.
    @MainActor public static func show(_ info: ReleaseInfo = ReleaseInfo()) {
        let credits: String =
            if let git = info.bundledGit {
                "Includes Git \(git.version), licensed under the GNU General Public License, version 2. Help ▸ Acknowledgements lists its license and where to get its source code."
            } else {
                "Development build: uses the Git installed on this Mac."
            }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(
            string: credits,
            attributes: [
                .font: TypeToken.caption.nsFont, .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: info.buildLine, .credits: text,
        ])
        NSApp.activate()
    }
}

/// Help ▸ Acknowledgements: every bundled third-party component with its license (a standard titled window).
@MainActor
public final class AcknowledgementsWindowController: NSWindowController {
    public init(info: ReleaseInfo = ReleaseInfo()) {
        let host = NSHostingController(rootView: AcknowledgementsView(info: info))
        let window = NSWindow(contentViewController: host)
        window.title = "Acknowledgements"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 560))
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.identifier = NSUserInterfaceItemIdentifier("acknowledgements")
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AcknowledgementsView: View {
    let info: ReleaseInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s5) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Jit \(info.version)").typeStyle(.title)
                    Text(info.copyright).typeStyle(.callout).foregroundStyle(.secondary)
                    Text(
                        "Jit is written entirely in Swift and uses only Apple's system frameworks. It runs Git as a separate program; it does not link Git's code."
                    )
                    .typeStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if let git = info.bundledGit {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text("Git \(git.version)").typeStyle(.headline)
                        Text(git.source)
                            .typeStyle(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("GNU General Public License, version 2").typeStyle(.headline).padding(.top, Space.s2)
                        Text(git.license)
                            .typeStyle(.monoCaption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(
                        "This development build doesn't include Git; it uses the Git installed on this Mac. Release builds bundle Git and list its license here."
                    )
                    .typeStyle(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ColorToken.surfaceCanvas.color)
    }
}
