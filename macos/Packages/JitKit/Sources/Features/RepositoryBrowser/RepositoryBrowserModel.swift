import Foundation
import GitCore
import Observation
import Services

/// What the browser asks its host to do. The browser never clones or switches profiles by itself.
public struct RepositoryBrowserActions {
    /// Starts the Phase 4 clone flow with this URL (the window controller's `presentClone(url:)`).
    public var clone: (String) -> Void
    /// Makes this profile active. Must switch synchronously (`ProfileStore.setActive`); the browser verifies the
    /// switch happened before it clones.
    public var switchProfile: (UUID) -> Void
    /// Opens Settings at a pane: `"accounts"` (connect/reconnect) or `"network"` (Test Connection…).
    public var openSettings: (String) -> Void

    public init(
        clone: @escaping (String) -> Void, switchProfile: @escaping (UUID) -> Void,
        openSettings: @escaping (String) -> Void
    ) {
        self.clone = clone
        self.switchProfile = switchProfile
        self.openSettings = openSettings
    }
}

/// GitHub's explicit "Search all accessible repositories" (design §4.7). `GitHubProvider` conforms; tests fake it.
public protocol AccessibleRepositorySearching: Sendable {
    func searchAll(query: String, login: String, orgs: [String]) async throws -> [RemoteRepository]
    func organizations() async throws -> [String]
}

extension GitHubProvider: AccessibleRepositorySearching {}

/// State of the remote repository browser (design §3.6) for one window. Makes no request until `open()`;
/// pages are cached in memory for this window only (`RepositoryCache`, 5-minute TTL) and dropped by `close()`.
/// Never retries on its own: offline, rate-limited and failed states wait for the user.
@MainActor @Observable
public final class RepositoryBrowserModel {
    public typealias ProviderFactory = @MainActor (HostingAccount) async -> (any HostingProvider)?

    public enum Phase: Equatable, Sendable {
        /// Not opened yet, or no account selected.
        case idle
        /// No hosting account is connected at all.
        case noAccounts
        case loading
        case loaded
        /// The account is expired or rejected; reconnect in Settings ▸ Accounts.
        case needsAttention(AccountStatus)
        case offline
        case rateLimited(resetAt: Date?)
        /// Any other failure. `canTestConnection` for self-managed instances (diagnostics in Settings).
        case failed(message: String, canTestConnection: Bool)
    }

    /// What the Clone button does for the browsed account (design §3.6: never clone under another account).
    public enum CloneAction: Equatable, Sendable {
        /// The active profile uses this account.
        case clone
        /// Another profile uses this account; switching to it first is required (and confirmed).
        case switchAndClone(profileID: UUID, profileName: String)
        /// No profile uses this account; cloning is disabled with this explanation.
        case unavailable(reason: String)
    }

    public struct PendingSwitch: Equatable, Sendable, Identifiable {
        public var profileID: UUID
        public var profileName: String
        public var url: String
        public var repositoryName: String
        public var id: String { url }
    }

    public enum SearchAllState: Equatable, Sendable {
        case idle
        case searching
        case failed(String)
    }

    // MARK: Dependencies

    public let profiles: ProfileStore
    @ObservationIgnored let providerFor: ProviderFactory
    @ObservationIgnored let isOffline: @MainActor () -> Bool
    @ObservationIgnored let actions: RepositoryBrowserActions
    @ObservationIgnored let debounce: Duration
    @ObservationIgnored private(set) var cache: RepositoryCache

    // MARK: State

    public private(set) var phase: Phase = .idle
    public private(set) var selectedAccountID: HostingAccountID?
    /// The search field's text. Applied 250 ms after the last keystroke.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleQuery()
        }
    }
    /// The debounced, trimmed query (`nil` = no filter).
    public private(set) var appliedQuery: String?
    /// Every repository loaded for the selected account (all pages so far).
    public private(set) var items: [RemoteRepository] = []
    /// What the list shows: `items` filtered locally (GitHub), server-filtered `items` (GitLab), or GitHub
    /// "Search all" results.
    public private(set) var displayedItems: [RemoteRepository] = []
    public private(set) var nextCursor: PageCursor?
    public private(set) var isLoadingMore = false
    /// A failed next-page request (the loaded rows stay).
    public private(set) var loadMoreFailure: String?
    /// GitHub "Search all accessible repositories" results; `nil` = showing loaded pages.
    public private(set) var searchAllResults: [RemoteRepository]?
    public private(set) var searchAllState: SearchAllState = .idle
    public var selectedRepositoryID: RemoteRepository.ID?
    public var transport: Transport = .https
    public var pendingSwitch: PendingSwitch?
    public private(set) var isOpen = false

    @ObservationIgnored private var displayedIndex: [RemoteRepository.ID: Int] = [:]
    @ObservationIgnored private var providers: [HostingAccountID: any HostingProvider] = [:]
    @ObservationIgnored private var organizations: [HostingAccountID: [String]] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var queryTask: Task<Void, Never>?
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?

    /// Organizations passed to GitHub "Search all" (keeps the query bounded).
    static let searchAllOrganizationLimit = 10

    public init(
        profiles: ProfileStore, actions: RepositoryBrowserActions, providerFor: @escaping ProviderFactory,
        isOffline: @escaping @MainActor () -> Bool = { false }, debounce: Duration = .milliseconds(250),
        cache: RepositoryCache = RepositoryCache(ttl: 300)
    ) {
        self.profiles = profiles
        self.actions = actions
        self.providerFor = providerFor
        self.isOffline = isOffline
        self.debounce = debounce
        self.cache = cache
    }

    /// The app's model: providers from `AccountsService.provider(for:)`, offline state from its connectivity.
    public convenience init(
        accounts: AccountsService, actions: RepositoryBrowserActions, providerFor: ProviderFactory? = nil
    ) {
        let connectivity = accounts.connectivity
        self.init(
            profiles: accounts.profiles, actions: actions,
            providerFor: providerFor ?? { [weak accounts] account in await accounts?.provider(for: account) },
            isOffline: { connectivity.path.status.isOffline })
    }

    // MARK: Accounts

    public var accounts: [HostingAccount] { profiles.accounts }

    public var selectedAccount: HostingAccount? { selectedAccountID.flatMap(profiles.account) }

    public var selectedInstance: ProviderInstance? { selectedAccount.flatMap { profiles.instance($0.instanceID) } }

    /// GitHub filters loaded pages locally; GitLab searches server-side (design §3.6, §4.7).
    public var filtersLocally: Bool { selectedInstance?.kind == .github }

    /// Accounts grouped by provider instance, in `allInstances` order (sidebar).
    public var accountGroups: [(instance: ProviderInstance, accounts: [HostingAccount])] {
        profiles.allInstances.compactMap { instance in
            let accounts = profiles.accounts.filter { $0.instanceID == instance.id }
            return accounts.isEmpty ? nil : (instance, accounts)
        }
    }

    /// The active profile's account, else the first connected account.
    var defaultAccountID: HostingAccountID? {
        if let profile = profiles.activeProfile, let account = profiles.account(for: profile) { return account.id }
        return profiles.accounts.first?.id
    }

    // MARK: Lifecycle

    /// Loads the first page. Nothing is requested before this (`noRequestsUntilBrowserOpened`). Idempotent.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        if selectedAccountID.flatMap(profiles.account) == nil { selectedAccountID = defaultAccountID }
        applyDefaultTransport()
        reload()
    }

    /// Cancels in-flight work and discards the cache and loaded pages (the window closed).
    public func close() {
        isOpen = false
        generation += 1
        queryTask?.cancel()
        loadTask?.cancel()
        searchTask?.cancel()
        queryTask = nil
        loadTask = nil
        searchTask = nil
        cache.removeAll()
        providers = [:]
        organizations = [:]
        items = []
        nextCursor = nil
        searchAllResults = nil
        pendingSwitch = nil
        refreshDisplayed()
        phase = .idle
    }

    public func selectAccount(_ id: HostingAccountID?) {
        guard id != selectedAccountID else { return }
        selectedAccountID = id
        selectedRepositoryID = nil
        applyDefaultTransport()
        if isOpen { reload() }
    }

    /// Retry after offline / rate limit / failure (explicit; nothing retries automatically).
    public func retry() {
        if let account = selectedAccount { cache.removeAll(accountID: account.id) }
        providers = [:]
        reload()
    }

    public func reconnect() { actions.openSettings("accounts") }
    public func connectAccount() { actions.openSettings("accounts") }
    public func testConnection() { actions.openSettings("network") }

    // MARK: Query

    private func scheduleQuery() {
        queryTask?.cancel()
        let delay = debounce
        queryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.applyQuery()
        }
    }

    func applyQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        guard normalized != appliedQuery else { return }
        appliedQuery = normalized
        searchTask?.cancel()
        searchAllResults = nil
        searchAllState = .idle
        if filtersLocally {
            refreshDisplayed()
        } else if isOpen {
            reload()
        }
    }

    // MARK: Loading

    private func reload() {
        loadTask?.cancel()
        generation += 1
        items = []
        nextCursor = nil
        isLoadingMore = false
        loadMoreFailure = nil
        refreshDisplayed()
        guard isOpen else {
            phase = .idle
            return
        }
        guard let account = selectedAccount else {
            phase = profiles.accounts.isEmpty ? .noAccounts : .idle
            return
        }
        if account.status.needsAttention {
            phase = .needsAttention(account.status)
            return
        }
        if isOffline() {
            phase = .offline
            return
        }
        phase = .loading
        let generation = generation
        loadTask = Task { [weak self] in await self?.fetchPage(account: account, cursor: nil, generation: generation) }
    }

    /// Loads the next page if there is one and nothing else is loading.
    public func loadNextPage() {
        guard isOpen, phase == .loaded, searchAllResults == nil, let cursor = nextCursor, !isLoadingMore,
            let account = selectedAccount
        else { return }
        if isOffline() {
            loadMoreFailure = "You're offline — Jit will not retry automatically."
            return
        }
        isLoadingMore = true
        loadMoreFailure = nil
        let generation = generation
        loadTask = Task { [weak self] in
            await self?.fetchPage(account: account, cursor: cursor, generation: generation)
        }
    }

    /// Called when a row becomes visible; prefetches the next page once a row at 80 % of the list appears.
    public func rowAppeared(_ id: RemoteRepository.ID) {
        guard let index = displayedIndex[id], Self.shouldPrefetch(index: index, count: displayedItems.count) else {
            return
        }
        loadNextPage()
    }

    /// `true` for the row at 80 % of the list and every row after it (index 39 of 50).
    nonisolated static func shouldPrefetch(index: Int, count: Int) -> Bool {
        guard count > 0, index >= 0, index < count else { return false }
        let threshold = Int((Double(count) * 0.8).rounded(.up))
        return index + 1 >= threshold
    }

    private func provider(for account: HostingAccount) async -> (any HostingProvider)? {
        if let cached = providers[account.id] { return cached }
        guard let provider = await providerFor(account) else { return nil }
        providers[account.id] = provider
        return provider
    }

    private func fetchPage(account: HostingAccount, cursor: PageCursor?, generation: Int) async {
        let query = filtersLocally ? nil : appliedQuery
        let key = RepositoryCache.Key(accountID: account.id, query: query, cursor: cursor)
        do {
            let page: RepositoryPage
            if let cached = cache.page(for: key) {
                page = cached
            } else {
                guard let provider = await provider(for: account) else { throw BrowserFailure.instanceRemoved }
                try Task.checkCancellation()
                page = try await provider.repositories(page: cursor, query: query)
                cache.store(page, for: key)
            }
            guard generation == self.generation else { return }
            var seen = Set(items.map(\.id))
            items += page.items.filter { seen.insert($0.id).inserted }
            nextCursor = page.next
            isLoadingMore = false
            phase = .loaded
            refreshDisplayed()
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            isLoadingMore = false
            let mapped = Self.phase(for: error, instance: selectedInstance, offline: isOffline())
            if case .needsAttention(let status) = mapped { profiles.setStatus(status, for: account.id) }
            if cursor == nil {
                phase = mapped
            } else {
                loadMoreFailure = Self.message(for: mapped)
            }
        }
    }

    enum BrowserFailure: Error {
        case instanceRemoved
    }

    /// Maps a provider failure to a browser state (design §3.6, §4.7).
    static func phase(for error: any Error, instance: ProviderInstance?, offline: Bool) -> Phase {
        let selfManaged = instance?.isSelfManaged == true
        switch error {
        case let error as ProviderError:
            switch error {
            case .unauthorized: return .needsAttention(.rejected)
            case .rateLimited(let resetAt): return .rateLimited(resetAt: resetAt)
            default: break
            }
            if offline || error.transportFailure == .offline { return .offline }
            return .failed(message: error.description, canTestConnection: selfManaged)
        case OAuthError.refreshFailed:
            return .needsAttention(.expired)
        case let error as OAuthError:
            if case .request(let inner) = error { return phase(for: inner, instance: instance, offline: offline) }
            return .failed(message: error.description, canTestConnection: false)
        case BrowserFailure.instanceRemoved:
            return .failed(message: "This account's server is no longer configured.", canTestConnection: false)
        default:
            if offline { return .offline }
            return .failed(message: "Jit couldn't load the repositories.", canTestConnection: selfManaged)
        }
    }

    /// One-line text for a state shown inline (next-page failures, "Search all" failures).
    static func message(for phase: Phase) -> String {
        switch phase {
        case .offline: return "You're offline — Jit will not retry automatically."
        case .rateLimited(let resetAt): return rateLimitText(resetAt)
        case .needsAttention: return "This account needs attention. Reconnect it in Settings ▸ Accounts."
        case .failed(let message, _): return message
        case .idle, .noAccounts, .loading, .loaded: return ""
        }
    }

    static func rateLimitText(_ resetAt: Date?) -> String {
        guard let resetAt else { return "The rate limit was reached. Try again later." }
        return "The rate limit was reached. It resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
    }

    // MARK: Filtering

    private func refreshDisplayed() {
        let shown: [RemoteRepository]
        if let searchAllResults {
            shown = searchAllResults
        } else if filtersLocally, let appliedQuery {
            shown = items.filter { Self.matches($0, appliedQuery) }
        } else {
            shown = items
        }
        displayedItems = shown
        var index: [RemoteRepository.ID: Int] = [:]
        index.reserveCapacity(shown.count)
        for (offset, repository) in shown.enumerated() { index[repository.id] = offset }
        displayedIndex = index
        if let selectedRepositoryID, index[selectedRepositoryID] == nil { self.selectedRepositoryID = nil }
    }

    /// Case- and diacritic-insensitive match on `owner/name` and the description (GitHub local filter).
    nonisolated static func matches(_ repository: RemoteRepository, _ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if repository.fullName.range(of: query, options: options) != nil { return true }
        return repository.description?.range(of: query, options: options) != nil
    }

    public var emptyMessage: String {
        if let appliedQuery { return "No repositories match '\(appliedQuery)'" }
        return "This account has no repositories."
    }

    // MARK: GitHub "Search all"

    /// Offered for GitHub with a query while showing loaded pages.
    public var canSearchAll: Bool { filtersLocally && appliedQuery != nil && searchAllResults == nil }

    /// GitHub `search/repositories` scoped to the account and (up to 10 of) its organizations — explicit, bounded.
    public func searchAllAccessible() {
        guard isOpen, filtersLocally, let account = selectedAccount, let query = appliedQuery else { return }
        if isOffline() {
            searchAllState = .failed(Self.message(for: .offline))
            return
        }
        searchTask?.cancel()
        searchAllState = .searching
        let generation = generation
        searchTask = Task { [weak self] in
            await self?.runSearchAll(account: account, query: query, generation: generation)
        }
    }

    private func runSearchAll(account: HostingAccount, query: String, generation: Int) async {
        do {
            guard let searcher = await provider(for: account) as? any AccessibleRepositorySearching else {
                throw BrowserFailure.instanceRemoved
            }
            let orgs: [String]
            if let known = organizations[account.id] {
                orgs = known
            } else {
                orgs = Array(try await searcher.organizations().prefix(Self.searchAllOrganizationLimit))
                organizations[account.id] = orgs
            }
            let results = try await searcher.searchAll(query: query, login: account.login, orgs: orgs)
            guard generation == self.generation, query == appliedQuery else { return }
            searchAllResults = results
            searchAllState = .idle
            refreshDisplayed()
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            let mapped = Self.phase(for: error, instance: selectedInstance, offline: isOffline())
            if case .needsAttention(let status) = mapped { profiles.setStatus(status, for: account.id) }
            searchAllState = .failed(Self.message(for: mapped))
        }
    }

    /// Back from "Search all" results to the loaded (locally filtered) pages.
    public func showLoadedRepositories() {
        searchTask?.cancel()
        searchAllResults = nil
        searchAllState = .idle
        refreshDisplayed()
    }

    // MARK: Clone

    public var selectedRepository: RemoteRepository? {
        guard let selectedRepositoryID, let index = displayedIndex[selectedRepositoryID] else { return nil }
        return displayedItems[index]
    }

    public func cloneAction(for account: HostingAccount) -> CloneAction {
        if let active = profiles.activeProfile, profiles.account(for: active)?.id == account.id { return .clone }
        if let profile = profiles.profiles(using: account.id).first {
            return .switchAndClone(profileID: profile.id, profileName: profile.displayName)
        }
        let host = profiles.instance(account.instanceID)?.httpsHost ?? ""
        return .unavailable(
            reason: "No profile uses @\(account.login)\(host.isEmpty ? "" : " on \(host)"). "
                + "Choose this account in a profile (Settings ▸ Profiles) to clone with it.")
    }

    public func cloneButtonTitle(for account: HostingAccount) -> String {
        if case .switchAndClone(_, let name) = cloneAction(for: account) { return "Clone with '\(name)'…" }
        return "Clone…"
    }

    public func cloneURL(for repository: RemoteRepository, transport: Transport) -> String? {
        switch transport {
        case .https: repository.httpsCloneURL?.absoluteString
        case .ssh: repository.sshCloneURL
        }
    }

    /// Clones with the active profile, or asks to switch first (`pendingSwitch`) when another profile owns the
    /// account. Never clones under a different account.
    public func clone(_ repository: RemoteRepository) {
        guard let account = selectedAccount, let url = cloneURL(for: repository, transport: transport) else { return }
        switch cloneAction(for: account) {
        case .clone:
            actions.clone(url)
        case .switchAndClone(let id, let name):
            pendingSwitch = PendingSwitch(
                profileID: id, profileName: name, url: url, repositoryName: repository.fullName)
        case .unavailable:
            return
        }
    }

    /// The user confirmed "Switch to '<profile>' and clone?". Clones only if the switch took effect.
    public func confirmPendingSwitch() {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        actions.switchProfile(pending.profileID)
        guard profiles.activeProfileID == pending.profileID else { return }
        actions.clone(pending.url)
    }

    public func cancelPendingSwitch() { pendingSwitch = nil }

    /// HTTPS/SSH default: the preferred transport of the profile that would clone (the active profile when it
    /// uses this account, else the profile to switch to), falling back to the active profile's, then HTTPS.
    private func applyDefaultTransport() {
        var profile = profiles.activeProfile
        if let account = selectedAccount, case .switchAndClone(let id, _) = cloneAction(for: account) {
            profile = profiles.profiles.first { $0.id == id } ?? profile
        }
        transport = profile?.auth?.preferredTransport ?? profiles.activeProfile?.auth?.preferredTransport ?? .https
    }
}
