import Foundation

/// Every bounded cache and size limit in one place (P6.6, ADR-0043). Values are counts or bytes; each cache
/// evicts on its own (oldest first) when it would exceed its limit, and `trimNotification` asks every cache to
/// drop what it can rebuild (memory pressure). Services and Features read these values; GitCore owns them so
/// the lower layers can use them too.
public enum CacheLimits {
    // MARK: Graph
    /// Materialized graph rows: windows of `graphRowWindow` rows, at most `graphRowWindows` windows (≈ 1k rows).
    public static let graphRowWindow = 64
    public static let graphRowWindows = 16
    /// Initials avatars rendered per graph (cleared when full).
    public static let graphAvatars = 1024

    // MARK: Diff / code
    /// `CTLine`s kept per code view (oldest quarter dropped when full).
    public static let codeLines = 4000
    /// Longest part of one line that is laid out (UTF-16 units).
    public static let renderedLineCharacters = 10_000
    /// Diffs larger than this show a "too large" message instead of rows.
    public static let diffBytes = 64 * 1024 * 1024
    /// Syntax highlighting only below these sizes (patch bytes / lines).
    public static let highlightBytes = 2 * 1024 * 1024
    public static let highlightLines = 50_000
    /// Word-level emphasis only for lines up to this many bytes.
    public static let wordDiffLineBytes = 1000

    // MARK: Command palette
    /// Tracked paths indexed per repository, and repositories whose index is kept.
    public static let paletteTrackedPaths = 100_000
    public static let paletteFileIndexRepositories = 2

    // MARK: Lists
    public static let recentRepositories = 20
    public static let reopenClosedTabs = 10
    public static let operationHistory = 20

    /// Posted on the main thread when the system reports memory pressure: caches that can be rebuilt are emptied.
    public static let trimNotification = Notification.Name("JitTrimCaches")
}
