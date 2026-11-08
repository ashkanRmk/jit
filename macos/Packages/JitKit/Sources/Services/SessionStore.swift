import Foundation

/// Arbitrary JSON, used for per-tab feature state that Phase 1 stores and round-trips without
/// interpreting (later phases fill it: graph scroll anchor, diff mode, composer draft, …).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// `session.json` (design §4.2).
public struct SessionState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct WindowFrame: Codable, Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Layout: Codable, Equatable, Sendable {
        public var sidebarWidth: Double
        public var inspectorWidth: Double

        public init(sidebarWidth: Double, inspectorWidth: Double) {
            self.sidebarWidth = sidebarWidth
            self.inspectorWidth = inspectorWidth
        }
    }

    public struct Tab: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case newTab
            case repository
        }

        public var id: UUID
        public var kind: Kind
        /// Standardized absolute path: working tree root, or git directory of a bare repository.
        public var path: String?
        public var titleCache: String
        public var branchCache: String?
        public var sidebarCollapsed: Bool
        public var inspectorCollapsed: Bool
        public var ui: [String: JSONValue]

        public init(
            id: UUID, kind: Kind, path: String? = nil, titleCache: String, branchCache: String? = nil,
            sidebarCollapsed: Bool = false, inspectorCollapsed: Bool = false, ui: [String: JSONValue] = [:]
        ) {
            self.id = id
            self.kind = kind
            self.path = path
            self.titleCache = titleCache
            self.branchCache = branchCache
            self.sidebarCollapsed = sidebarCollapsed
            self.inspectorCollapsed = inspectorCollapsed
            self.ui = ui
        }
    }

    public var version: Int
    public var windowFrame: WindowFrame?
    public var layout: Layout?
    public var tabs: [Tab]
    public var activeTabID: UUID?

    public init(
        windowFrame: WindowFrame? = nil, layout: Layout? = nil, tabs: [Tab] = [], activeTabID: UUID? = nil
    ) {
        self.version = Self.currentVersion
        self.windowFrame = windowFrame
        self.layout = layout
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

/// Reads and writes `session.json`. Loading is synchronous (a small file read before the first
/// window); saving is debounced and atomic.
@MainActor
public final class SessionStore {
    public let url: URL
    private let writer: DebouncedWriter

    public init(location: StoreLocation = .applicationSupport(), fileName: String = "session.json") {
        url = location.url(fileName)
        writer = DebouncedWriter(url: url)
    }

    public func load() -> JSONFile.LoadOutcome<SessionState> {
        JSONFile.load(SessionState.self, at: url, version: SessionState.currentVersion)
    }

    /// Schedules a write; `state` is evaluated when the write happens, so bursts cost one encode.
    public func save(_ state: @escaping @MainActor () -> SessionState) {
        writer.schedule { try? JSONFile.encode(state()) }
    }

    public func flush() { writer.flush() }
}
