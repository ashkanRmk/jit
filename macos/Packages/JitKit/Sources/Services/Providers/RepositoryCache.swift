import Foundation
import Synchronization

/// In-memory repository-page cache for one browser window (design §4.7): 5-minute TTL, bounded entry count,
/// nothing on disk. Discard it with the window.
public final class RepositoryCache: Sendable {
    public struct Key: Sendable, Hashable {
        public var accountID: HostingAccountID
        public var query: String?
        public var cursor: PageCursor?

        public init(accountID: HostingAccountID, query: String? = nil, cursor: PageCursor? = nil) {
            self.accountID = accountID
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.query = trimmed?.isEmpty == false ? trimmed : nil
            self.cursor = cursor
        }
    }

    private struct Entry {
        var page: RepositoryPage
        var storedAt: Date
    }

    private struct State {
        var entries: [Key: Entry] = [:]
    }

    public let ttl: TimeInterval
    public let maxEntries: Int
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    public init(ttl: TimeInterval = 300, maxEntries: Int = 64, now: @escaping @Sendable () -> Date = Date.init) {
        self.ttl = ttl
        self.maxEntries = max(1, maxEntries)
        self.now = now
    }

    /// The cached page if it is younger than `ttl`; expired entries are dropped on access.
    public func page(for key: Key) -> RepositoryPage? {
        let time = now()
        return state.withLock { state in
            guard let entry = state.entries[key] else { return nil }
            if time.timeIntervalSince(entry.storedAt) >= ttl {
                state.entries[key] = nil
                return nil
            }
            return entry.page
        }
    }

    /// Stores a page; when full, expired entries go first, then the oldest.
    public func store(_ page: RepositoryPage, for key: Key) {
        let time = now()
        state.withLock { state in
            state.entries[key] = Entry(page: page, storedAt: time)
            guard state.entries.count > maxEntries else { return }
            state.entries = state.entries.filter { time.timeIntervalSince($0.value.storedAt) < ttl }
            while state.entries.count > maxEntries,
                let oldest = state.entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
            {
                state.entries[oldest] = nil
            }
        }
    }

    /// Returns the cached page or fetches and stores it. Concurrent misses may fetch twice (harmless; the
    /// browser issues one request per user action).
    public func page(for key: Key, fetch: () async throws -> RepositoryPage) async throws -> RepositoryPage {
        if let cached = page(for: key) { return cached }
        let fresh = try await fetch()
        store(fresh, for: key)
        return fresh
    }

    /// Drops everything for one account (e.g. after reconnecting) or all accounts.
    public func removeAll(accountID: HostingAccountID? = nil) {
        state.withLock { state in
            if let accountID {
                state.entries = state.entries.filter { $0.key.accountID != accountID }
            } else {
                state.entries.removeAll()
            }
        }
    }

    public var count: Int { state.withLock { $0.entries.count } }
}
