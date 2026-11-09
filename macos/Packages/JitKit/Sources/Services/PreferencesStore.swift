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

    /// Row density of the commit graph (View ▸ Compact / Comfortable).
    public enum GraphDensity: String, CaseIterable, Sendable {
        case compact, comfortable

        public var title: String { self == .compact ? "Compact" : "Comfortable" }
    }

    static let appearanceKey = "appearance"
    static let graphDensityKey = "graphDensity"
    static let restoreTabsKey = "restoreTabsOnLaunch"
    static let commandBarLabelsKey = "commandBarShowsLabels"
    static let cloneParentKey = "cloneParentDirectory"

    @ObservationIgnored private let defaults: UserDefaults

    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    public var restoreTabsOnLaunch: Bool {
        didSet { defaults.set(restoreTabsOnLaunch, forKey: Self.restoreTabsKey) }
    }

    public var graphDensity: GraphDensity {
        didSet { defaults.set(graphDensity.rawValue, forKey: Self.graphDensityKey) }
    }

    /// View ▸ Command Bar ▸ Show Labels. Off: icon-only buttons with tooltips at every width.
    public var commandBarShowsLabels: Bool {
        didSet { defaults.set(commandBarShowsLabels, forKey: Self.commandBarLabelsKey) }
    }

    /// Where the clone sheet creates repositories (remembered; defaults to ~/Developer if it exists, else home).
    public var cloneParentDirectory: String {
        didSet { defaults.set(cloneParentDirectory, forKey: Self.cloneParentKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
        restoreTabsOnLaunch = defaults.object(forKey: Self.restoreTabsKey) as? Bool ?? true
        graphDensity =
            defaults.string(forKey: Self.graphDensityKey).flatMap(GraphDensity.init(rawValue:)) ?? .comfortable
        commandBarShowsLabels = defaults.object(forKey: Self.commandBarLabelsKey) as? Bool ?? true
        let developer = NSHomeDirectory() + "/Developer"
        cloneParentDirectory =
            defaults.string(forKey: Self.cloneParentKey)
            ?? (FileManager.default.fileExists(atPath: developer) ? developer : NSHomeDirectory())
    }
}
