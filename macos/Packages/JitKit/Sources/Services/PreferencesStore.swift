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
    static let codeTextSizeKey = "codeTextSize"

    /// App-level text size step for code and diff views (P6.10): View ▸ Larger / Smaller Code Text.
    public enum CodeTextSize: Int, CaseIterable, Sendable {
        case small = -1, medium = 0, large = 1, extraLarge = 2

        public var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }
    }

    /// Posted on the main thread when `codeTextSize` changes (code views re-measure).
    public static let codeTextSizeDidChange = Notification.Name("JitCodeTextSizeDidChange")

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
    public var codeTextSize: CodeTextSize {
        didSet {
            defaults.set(codeTextSize.rawValue, forKey: Self.codeTextSizeKey)
            NotificationCenter.default.post(name: Self.codeTextSizeDidChange, object: nil)
        }
    }

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
        codeTextSize = CodeTextSize(rawValue: defaults.integer(forKey: Self.codeTextSizeKey)) ?? .medium
        graphDensity =
            defaults.string(forKey: Self.graphDensityKey).flatMap(GraphDensity.init(rawValue:)) ?? .comfortable
        commandBarShowsLabels = defaults.object(forKey: Self.commandBarLabelsKey) as? Bool ?? true
        let developer = NSHomeDirectory() + "/Developer"
        cloneParentDirectory =
            defaults.string(forKey: Self.cloneParentKey)
            ?? (FileManager.default.fileExists(atPath: developer) ? developer : NSHomeDirectory())
    }
}
