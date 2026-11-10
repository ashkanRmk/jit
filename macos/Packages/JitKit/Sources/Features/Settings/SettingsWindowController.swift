import AppKit
import DesignSystem
import GitCore
import Services
import SwiftUI

/// Settings (⌘,) in the macOS System Settings style (design §3.2): a `NavigationSplitView` with the system
/// sidebar (Liquid Glass by the system) and grouped `Form` panes — General, Profiles, Accounts, Servers &
/// Network, Git. No custom chrome.
@MainActor
public final class SettingsWindowController: NSWindowController {
    public enum Pane: String, CaseIterable, Identifiable, Sendable {
        case general, profiles, accounts, network, git

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .profiles: "Profiles"
            case .accounts: "Accounts"
            case .network: "Servers & Network"
            case .git: "Git"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .profiles: "person.2"
            case .accounts: "person.crop.circle.badge.checkmark"
            case .network: "network"
            case .git: "terminal"
            }
        }
    }

    let navigation = SettingsNavigation()

    public init(preferences: PreferencesStore, accounts: AccountsService, engine: GitEngine) {
        let root = SettingsRootView(
            navigation: navigation, preferences: preferences, accounts: accounts, engine: engine)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 560))
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.title = "Settings"
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show(_ pane: Pane? = nil) {
        if let pane { navigation.pane = pane }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor @Observable
final class SettingsNavigation {
    var pane: SettingsWindowController.Pane = .general
}

struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation
    let preferences: PreferencesStore
    let accounts: AccountsService
    let engine: GitEngine

    var body: some View {
        NavigationSplitView {
            List(SettingsWindowController.Pane.allCases, selection: $navigation.pane.optional) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch navigation.pane {
                case .general: GeneralSettingsView(preferences: preferences)
                case .profiles:
                    ProfilesSettingsView(accounts: accounts, engine: engine) { navigation.pane = $0 }
                case .accounts: AccountsSettingsView(accounts: accounts) { navigation.pane = $0 }
                case .network: NetworkSettingsView(accounts: accounts)
                case .git: GitSettingsView(preferences: preferences, engine: engine)
                }
            }
            .navigationTitle(navigation.pane.title)
        }
    }
}

extension Binding where Value == SettingsWindowController.Pane {
    /// `List(selection:)` wants an optional; deselecting keeps the current pane.
    var optional: Binding<SettingsWindowController.Pane?> {
        Binding<SettingsWindowController.Pane?>(
            get: { wrappedValue }, set: { if let value = $0 { wrappedValue = value } })
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
            Section {
                Toggle("Show author pictures from Gravatar", isOn: $preferences.showsGravatarAvatars)
            } footer: {
                Text(
                    "Jit asks gravatar.com for a picture using a hash of each author's email address, for commits on screen. Authors without one keep their initials."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
