import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Settings (⌘,): General and Profiles panes in a standard toolbar-style settings window (system glass
/// toolbar/tabs on macOS 26).
@MainActor
public final class SettingsWindowController: NSWindowController {
    public enum Pane: Int {
        case general, profiles
    }

    private let tabs = NSTabViewController()

    public init(preferences: PreferencesStore, profiles: ProfileStore, engine: GitEngine) {
        tabs.tabStyle = .toolbar
        let general = NSHostingController(rootView: GeneralSettingsView(preferences: preferences))
        general.sizingOptions = .preferredContentSize
        general.title = "General"  // the selected pane's title becomes the window title
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        let profilesHost = NSHostingController(rootView: ProfilesSettingsView(store: profiles, engine: engine))
        profilesHost.sizingOptions = .preferredContentSize
        profilesHost.title = "Profiles"
        let profilesItem = NSTabViewItem(viewController: profilesHost)
        profilesItem.label = "Profiles"
        profilesItem.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: "Profiles")
        tabs.addTabViewItem(generalItem)
        tabs.addTabViewItem(profilesItem)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show(_ pane: Pane? = nil) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GeneralSettingsView: View {
    @Bindable var preferences: PreferencesStore

    var body: some View {
        Form {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(PreferencesStore.Appearance.allCases, id: \.self) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Restore tabs on launch", isOn: $preferences.restoreTabsOnLaunch)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
