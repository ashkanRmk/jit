import DesignSystem
import Features
import GitCore
import SwiftUI

@main
struct JitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Creating the engine does no I/O; Git is located on first use, off the main actor.
    @State private var model = FoundationModel(engine: GitEngine())

    init() {
        LaunchProbe.startIfRequested()
    }

    var body: some Scene {
        Window("Jit", id: "main") {
            FoundationView(model: model)
                .frame(minWidth: PanelMetrics.windowMinWidth, minHeight: PanelMetrics.windowMinHeight)
                .onDisappear { model.cancel() }
                .onAppear {
                    LaunchProbe.firstContentAppeared()
                    // `-JitOpen <path>` or env `JIT_OPEN=<path>`: open a folder at launch (benchmarks, manual
                    // checks). Use the env form with `open`, where AppKit treats path arguments as files.
                    if let path = ProcessInfo.processInfo.environment["JIT_OPEN"]
                        ?? UserDefaults.standard.string(forKey: "JitOpen")
                    {
                        model.open(URL(fileURLWithPath: path))
                    }
                }
                #if DEBUG
                    .modifier(DebugLaunchActions())
                #endif
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            #if DEBUG
                CommandMenu("Debug") { DesignSystemMenuItem() }
            #endif
        }

        #if DEBUG
            Window("Design System", id: "design-system") {
                DesignSystemGallery()
                    .frame(minWidth: 900, minHeight: 600)
            }
            .defaultSize(width: 1180, height: 820)
        #endif
    }
}

#if DEBUG
    private struct DesignSystemMenuItem: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Design System") { openWindow(id: "design-system") }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
    }
#endif
