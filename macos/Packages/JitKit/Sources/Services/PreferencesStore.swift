import Foundation
import Observation

/// User preferences (`UserDefaults`).
@MainActor @Observable
public final class PreferencesStore {
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark

        public var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    static let appearanceKey = "appearance"
    static let restoreTabsKey = "restoreTabsOnLaunch"

    @ObservationIgnored private let defaults: UserDefaults

    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    public var restoreTabsOnLaunch: Bool {
        didSet { defaults.set(restoreTabsOnLaunch, forKey: Self.restoreTabsKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
        restoreTabsOnLaunch = defaults.object(forKey: Self.restoreTabsKey) as? Bool ?? true
    }
}
