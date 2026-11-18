import AppKit
import DesignSystem
import Services
import SwiftUI
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct ZoomTypographyTests {
    private struct FontProbe: View {
        let report: (CGFloat) -> Void
        @Environment(\.font) private var font
        @Environment(\.fontResolutionContext) private var context

        var body: some View {
            let pointSize = (font ?? TypeToken.body.font).resolve(in: context).pointSize
            Text("Sharp text 0123")
                .onChange(of: pointSize, initial: true) { _, value in report(value) }
        }
    }

    @Test func textSymbolsAndNestedStylesRenderAtTheDestinationFontSize() async throws {
        _ = NSApplication.shared
        var bodySize: CGFloat = 0
        var symbolSize: CGFloat = 0
        var nestedSize: CGFloat = 0
        let host = WorkspaceHostingView(
            rootView: VStack(alignment: .leading) {
                FontProbe { bodySize = $0 }.typeStyle(.body)
                FontProbe { symbolSize = $0 }.symbolSize(IconSize.md)
                FontProbe { nestedSize = $0 }.typeStyle(.caption).scaledFont(TypeToken.title.font)
            })
        host.sizingOptions = []
        host.frame = NSRect(x: 20, y: 400, width: 400, height: 100)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        canvas.addSubview(host)
        let viewport = WorkspaceZoomView()
        viewport.documentView = canvas
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = viewport
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for level in PreferencesStore.ZoomLevel.allCases {
            let scale = CGFloat(level.factor)
            viewport.setZoom(scale)
            window.layoutIfNeeded()
            viewport.layoutSubtreeIfNeeded()
            // The platform font resolver rounds fractional sizes to quarter points.
            #expect(
                await ClosedTabDeallocatesTests.waitUntil {
                    abs(bodySize - TypeToken.body.size * scale) < 0.13
                        && abs(symbolSize - IconSize.md * scale) < 0.13
                        && abs(nestedSize - TypeToken.caption.size * scale) < 0.13
                }, "Native glyph sizes must follow zoom \(scale): \(bodySize), \(symbolSize), \(nestedSize)")
        }
    }

    @Test func multilineTextKeepsItsFirstBaselineWithEnlargedGlyphs() async throws {
        _ = NSApplication.shared
        var bodyHeight: CGFloat = 0
        var titleY: CGFloat = -1
        let host = WorkspaceHostingView(
            rootView: HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Several lines of text must wrap without moving the title to the last line.")
                    .typeStyle(.body)
                    .frame(width: 100)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        bodyHeight = $0
                    }
                Text("Title").typeStyle(.title)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .named("baselines")).minY
                    } action: {
                        titleY = $0
                    }
            }.coordinateSpace(name: "baselines").environment(\.workspaceZoomFactor, 1.5))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 160)
        _ = Snapshot.render(host, size: NSSize(width: 300, height: 160), variant: .light)
        #expect(await ClosedTabDeallocatesTests.waitUntil { bodyHeight > 40 && titleY >= 0 })
        // Losing the custom layout's first baseline would align the title to the paragraph's bottom.
        #expect(titleY < 10)
    }
}
