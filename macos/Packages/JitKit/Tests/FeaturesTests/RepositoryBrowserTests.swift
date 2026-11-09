import Foundation
import GitCore
import Synchronization
import Testing

@testable import Features
@testable import Services

/// A recording `HostingProvider` (and GitHub "Search all") with scripted pages and failures.
final class FakeHostingProvider: HostingProvider, AccessibleRepositorySearching {
    struct Call: Equatable, Sendable {
        var cursor: PageCursor?
        var query: String?
    }

    struct State {
        var calls: [Call] = []
        var searchAllCalls: [(query: String, login: String, orgs: [String])] = []
        var organizationCalls = 0
        var pages: [RepositoryPage] = []
        var failure: (any Error)?
    }

    let state = Mutex(State())

    init(pages: [RepositoryPage] = [], failure: (any Error)? = nil) {
        state.withLock {
            $0.pages = pages
            $0.failure = failure
        }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var searchAllQueries: [String] { state.withLock { $0.searchAllCalls.map(\.query) } }

    func setFailure(_ error: (any Error)?) { state.withLock { $0.failure = error } }

    func currentUser() async throws -> ProviderUser { ProviderUser(id: "1", login: "octo") }
    func tokenInfo() async throws -> TokenInfo { TokenInfo(scopes: []) }
    func publishedSSHFingerprints() async throws -> [String] { [] }

    func repositories(page: PageCursor?, query: String?) async throws -> RepositoryPage {
        try state.withLock { state in
            state.calls.append(Call(cursor: page, query: query))
            if let failure = state.failure { throw failure }
            let index: Int
            switch page?.storage {
            case .page(let number)?: index = number - 1
            default: index = 0
            }
            guard state.pages.indices.contains(index) else { return RepositoryPage(items: [], next: nil) }
            return state.pages[index]
        }
    }

    func searchAll(query: String, login: String, orgs: [String]) async throws -> [RemoteRepository] {
        state.withLock { $0.searchAllCalls.append((query, login, orgs)) }
        return [repo("search-hit", owner: "acme")]
    }

    func organizations() async throws -> [String] {
        state.withLock {
            $0.organizationCalls += 1
            return ["acme"]
        }
    }
}

func repo(_ name: String, owner: String = "octo", description: String? = nil) -> RemoteRepository {
    RemoteRepository(
        id: "\(owner)/\(name)", owner: owner, name: name, fullName: "\(owner)/\(name)", description: description,
        visibility: .private, defaultBranch: "main",
        httpsCloneURL: URL(string: "https://example.com/\(owner)/\(name).git"),
        sshCloneURL: "git@example.com:\(owner)/\(name).git")
}

func pages(_ count: Int, perPage: Int = 50) -> [RepositoryPage] {
    (1...count).map { number in
        RepositoryPage(
            items: (0..<perPage).map { repo("r\(number)-\($0)") },
            next: number < count ? PageCursor(.page(number + 1)) : nil)
    }
}

@MainActor
@Suite struct RepositoryBrowserTests {
    final class Recorder {
        var cloned: [String] = []
        var switched: [UUID] = []
        var settings: [String] = []
        var factoryCalls = 0
    }

    struct World {
        let model: RepositoryBrowserModel
        let profiles: ProfileStore
        let provider: FakeHostingProvider
        let recorder: Recorder
        let github: HostingAccount
        let gitlab: HostingAccount
        let workID: UUID
        let personalID: UUID
        let root: URL
    }

    /// Two accounts (GitHub `octo`, GitLab.com `worker`), profiles "Personal" (GitHub, active, SSH preferred) and
    /// "Work GitLab" (GitLab account).
    func makeWorld(
        provider: FakeHostingProvider = FakeHostingProvider(pages: pages(1)), offline: Bool = false,
        githubStatus: AccountStatus = .ok, debounce: Duration = .milliseconds(30)
    ) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jit-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profiles = ProfileStore(location: StoreLocation(directory: root))
        let github = HostingAccount(
            instanceID: .github, login: "octo", userID: "1", method: .pat, status: githubStatus)
        let gitlab = HostingAccount(instanceID: .gitlab, login: "worker", userID: "2", method: .pat)
        profiles.addAccount(github)
        profiles.addAccount(gitlab)
        let identity = GitIdentity(name: "A", email: "a@example.com")
        let personal = GitProfile(
            displayName: "Personal", colorIndex: 0, author: identity,
            auth: ProfileAuth(instanceID: .github, accountID: github.id, preferredTransport: .ssh))
        let work = GitProfile(
            displayName: "Work GitLab", colorIndex: 1, author: identity,
            auth: ProfileAuth(instanceID: .gitlab, accountID: gitlab.id, preferredTransport: .https))
        profiles.create(personal, activate: true)
        profiles.create(work)
        let recorder = Recorder()
        let model = RepositoryBrowserModel(
            profiles: profiles,
            actions: RepositoryBrowserActions(
                clone: { recorder.cloned.append($0) },
                switchProfile: { id in
                    recorder.switched.append(id)
                    profiles.setActive(id)
                },
                openSettings: { recorder.settings.append($0) }),
            providerFor: { _ in
                recorder.factoryCalls += 1
                return provider
            },
            isOffline: { offline }, debounce: debounce)
        return World(
            model: model, profiles: profiles, provider: provider, recorder: recorder, github: github, gitlab: gitlab,
            workID: work.id, personalID: personal.id, root: root)
    }

    func settle(_ model: RepositoryBrowserModel) async {
        await model.queryTask?.value
        await model.loadTask?.value
        await model.searchTask?.value
    }

    // MARK: Requests

    @Test func noRequestsUntilBrowserOpened() async throws {
        let world = try makeWorld()
        world.model.query = "abc"
        world.model.selectAccount(world.gitlab.id)
        try await Task.sleep(for: .milliseconds(80))
        await settle(world.model)
        #expect(world.recorder.factoryCalls == 0)
        #expect(world.provider.calls.isEmpty)
        #expect(world.model.phase == .idle)

        world.model.open()
        await settle(world.model)
        #expect(world.provider.calls.count == 1)
        #expect(world.model.phase == .loaded)
    }

    @Test func opensOnActiveProfilesAccountAndTransport() async throws {
        let world = try makeWorld()
        world.model.open()
        await settle(world.model)
        #expect(world.model.selectedAccountID == world.github.id)
        #expect(world.model.transport == .ssh)
        #expect(world.model.displayedItems.count == 50)
    }

    @Test func paginationTriggersAtEightyPercent() async throws {
        #expect(!RepositoryBrowserModel.shouldPrefetch(index: 38, count: 50))
        #expect(RepositoryBrowserModel.shouldPrefetch(index: 39, count: 50))
        #expect(RepositoryBrowserModel.shouldPrefetch(index: 49, count: 50))
        #expect(!RepositoryBrowserModel.shouldPrefetch(index: 0, count: 0))

        let world = try makeWorld(provider: FakeHostingProvider(pages: pages(3)))
        world.model.open()
        await settle(world.model)
        let items = world.model.displayedItems
        world.model.rowAppeared(items[10].id)
        world.model.rowAppeared(items[38].id)
        #expect(world.provider.calls.count == 1)
        world.model.rowAppeared(items[39].id)
        world.model.rowAppeared(items[40].id)  // already loading: no second request
        await settle(world.model)
        #expect(world.provider.calls.count == 2)
        #expect(world.provider.calls[1].cursor == PageCursor(.page(2)))
        #expect(world.model.displayedItems.count == 100)
        #expect(world.recorder.factoryCalls == 1)  // one provider client per account

        world.model.rowAppeared(world.model.displayedItems[79].id)
        await settle(world.model)
        #expect(world.model.displayedItems.count == 150)
        #expect(world.model.nextCursor == nil)
        world.model.rowAppeared(world.model.displayedItems[149].id)
        await settle(world.model)
        #expect(world.provider.calls.count == 3)
    }

    @Test func debounceCancelsEarlierQueryTasks() async throws {
        let world = try makeWorld()
        world.model.selectAccount(world.gitlab.id)
        world.model.open()
        await settle(world.model)
        #expect(world.provider.calls.map(\.query) == [nil])

        world.model.query = "a"
        let first = world.model.queryTask
        world.model.query = "ab"
        let second = world.model.queryTask
        world.model.query = "abc"
        #expect(first?.isCancelled == true)
        #expect(second?.isCancelled == true)
        await settle(world.model)
        #expect(world.provider.calls.map(\.query) == [nil, "abc"])
        #expect(world.model.appliedQuery == "abc")
    }

    @Test func gitLabSearchesServerSide() async throws {
        let world = try makeWorld()
        world.model.selectAccount(world.gitlab.id)
        world.model.open()
        await settle(world.model)
        #expect(!world.model.filtersLocally)
        world.model.query = "  infra "
        await settle(world.model)
        #expect(world.provider.calls.last?.query == "infra")
        #expect(!world.model.canSearchAll)
        // The same query again is served from the window's cache.
        world.model.query = ""
        await settle(world.model)
        world.model.query = "infra"
        await settle(world.model)
        #expect(world.provider.calls.map(\.query) == [nil, "infra"])
    }

    @Test func gitHubFiltersLoadedPagesLocally() async throws {
        let provider = FakeHostingProvider(pages: [
            RepositoryPage(
                items: [repo("jit", description: "Git client"), repo("dotfiles"), repo("notes", description: "JIT")],
                next: nil)
        ])
        let world = try makeWorld(provider: provider)
        world.model.open()
        await settle(world.model)
        #expect(world.model.filtersLocally)
        world.model.query = "jit"
        await settle(world.model)
        #expect(provider.calls.count == 1)
        #expect(provider.calls[0].query == nil)
        #expect(world.model.displayedItems.map(\.name) == ["jit", "notes"])

        world.model.query = "nothing-here"
        await settle(world.model)
        #expect(world.model.displayedItems.isEmpty)
        #expect(world.model.emptyMessage == "No repositories match 'nothing-here'")
        #expect(world.model.canSearchAll)

        world.model.searchAllAccessible()
        await settle(world.model)
        #expect(provider.searchAllQueries == ["nothing-here"])
        #expect(provider.state.withLock { $0.searchAllCalls.first?.orgs } == ["acme"])
        #expect(world.model.displayedItems.map(\.name) == ["search-hit"])
        #expect(!world.model.canSearchAll)

        world.model.showLoadedRepositories()
        #expect(world.model.displayedItems.isEmpty)
        #expect(provider.calls.count == 1)
    }

    // MARK: States

    @Test func errorStateMapping() {
        let github = ProviderInstance.github
        let selfManaged = ProviderInstance(
            id: ProviderInstanceID(rawValue: "corp"), kind: .gitlab, name: "Corp",
            webBaseURL: URL(fileURLWithPath: "/").deletingLastPathComponent(), sshHost: "git.corp.example")
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        typealias Model = RepositoryBrowserModel
        #expect(
            Model.phase(for: ProviderError.rateLimited(resetAt: reset), instance: github, offline: false)
                == .rateLimited(resetAt: reset))
        #expect(
            Model.phase(for: ProviderError.unauthorized, instance: github, offline: false) == .needsAttention(.rejected)
        )
        #expect(
            Model.phase(for: OAuthError.refreshFailed, instance: github, offline: false) == .needsAttention(.expired))
        #expect(
            Model.phase(
                for: ProviderError.transport(URLError(.notConnectedToInternet)), instance: github, offline: false)
                == .offline)
        #expect(Model.phase(for: ProviderError.server(502), instance: github, offline: true) == .offline)
        #expect(
            Model.phase(for: ProviderError.transport(URLError(.cannotFindHost)), instance: selfManaged, offline: false)
                == .failed(
                    message: ProviderError.transport(URLError(.cannotFindHost)).description, canTestConnection: true))
        #expect(
            Model.phase(for: ProviderError.server(500), instance: github, offline: false)
                == .failed(message: ProviderError.server(500).description, canTestConnection: false))
        #expect(Model.rateLimitText(reset).contains("resets at"))
    }

    @Test func rateLimitedResponseShowsResetAndNeverRetries() async throws {
        let reset = Date().addingTimeInterval(600)
        let provider = FakeHostingProvider(failure: ProviderError.rateLimited(resetAt: reset))
        let world = try makeWorld(provider: provider)
        world.model.open()
        await settle(world.model)
        #expect(world.model.phase == .rateLimited(resetAt: reset))
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.calls.count == 1)

        provider.setFailure(nil)
        world.model.retry()
        await settle(world.model)
        #expect(world.model.phase == .loaded)
        #expect(provider.calls.count == 2)
    }

    @Test func offlineMakesNoRequest() async throws {
        let world = try makeWorld(offline: true)
        world.model.open()
        await settle(world.model)
        #expect(world.model.phase == .offline)
        #expect(world.provider.calls.isEmpty)
    }

    @Test func needsAttentionAccountMakesNoRequestAndPointsAtSettings() async throws {
        let world = try makeWorld(githubStatus: .expired)
        world.model.open()
        await settle(world.model)
        #expect(world.model.phase == .needsAttention(.expired))
        #expect(world.provider.calls.isEmpty)
        world.model.reconnect()
        #expect(world.recorder.settings == ["accounts"])
    }

    @Test func unauthorizedMarksAccountRejected() async throws {
        let world = try makeWorld(provider: FakeHostingProvider(failure: ProviderError.unauthorized))
        world.model.open()
        await settle(world.model)
        #expect(world.model.phase == .needsAttention(.rejected))
        #expect(world.profiles.account(world.github.id)?.status == .rejected)
    }

    @Test func noAccountsState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jit-browser-\(UUID().uuidString)")
        let profiles = ProfileStore(location: StoreLocation(directory: root))
        var settings: [String] = []
        let model = RepositoryBrowserModel(
            profiles: profiles,
            actions: RepositoryBrowserActions(
                clone: { _ in }, switchProfile: { _ in }, openSettings: { settings.append($0) }),
            providerFor: { _ in nil })
        model.open()
        #expect(model.phase == .noAccounts)
        model.connectAccount()
        #expect(settings == ["accounts"])
    }

    // MARK: Clone

    @Test func cloneWithActiveProfilesAccount() async throws {
        let world = try makeWorld()
        world.model.open()
        await settle(world.model)
        let first = try #require(world.model.displayedItems.first)
        #expect(world.model.cloneAction(for: world.github) == .clone)
        #expect(world.model.cloneButtonTitle(for: world.github) == "Clone…")
        world.model.clone(first)  // SSH preferred by "Personal"
        #expect(world.recorder.cloned == ["git@example.com:octo/r1-0.git"])
        world.model.transport = .https
        world.model.clone(first)
        #expect(world.recorder.cloned.last == "https://example.com/octo/r1-0.git")
        #expect(world.recorder.switched.isEmpty)
    }

    @Test func otherAccountRequiresConfirmedSwitchBeforeClone() async throws {
        let world = try makeWorld()
        world.model.selectAccount(world.gitlab.id)
        world.model.open()
        await settle(world.model)
        #expect(world.model.transport == .https)  // "Work GitLab" prefers HTTPS
        #expect(world.model.cloneButtonTitle(for: world.gitlab) == "Clone with 'Work GitLab'…")
        let first = try #require(world.model.displayedItems.first)

        world.model.clone(first)
        #expect(world.recorder.cloned.isEmpty)
        #expect(world.model.pendingSwitch?.profileName == "Work GitLab")
        world.model.cancelPendingSwitch()
        #expect(world.recorder.cloned.isEmpty)
        #expect(world.recorder.switched.isEmpty)

        world.model.clone(first)
        world.model.confirmPendingSwitch()
        #expect(world.recorder.switched == [world.workID])
        #expect(world.profiles.activeProfileID == world.workID)
        #expect(world.recorder.cloned == ["https://example.com/octo/r1-0.git"])
        #expect(world.model.cloneAction(for: world.gitlab) == .clone)
    }

    @Test func noCloneWhenSwitchDidNotHappen() async throws {
        let world = try makeWorld()
        var cloned: [String] = []
        let model = RepositoryBrowserModel(
            profiles: world.profiles,
            actions: RepositoryBrowserActions(
                clone: { cloned.append($0) }, switchProfile: { _ in }, openSettings: { _ in }),
            providerFor: { _ in world.provider })
        model.selectAccount(world.gitlab.id)
        model.open()
        await settle(model)
        model.clone(try #require(model.displayedItems.first))
        model.confirmPendingSwitch()
        #expect(cloned.isEmpty)
    }

    @Test func accountWithoutProfileCannotClone() async throws {
        let world = try makeWorld()
        let orphan = HostingAccount(instanceID: .gitlab, login: "nobody", userID: "3", method: .pat)
        world.profiles.addAccount(orphan)
        world.model.selectAccount(orphan.id)
        world.model.open()
        await settle(world.model)
        guard case .unavailable(let reason) = world.model.cloneAction(for: orphan) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("@nobody"))
        world.model.clone(try #require(world.model.displayedItems.first))
        #expect(world.recorder.cloned.isEmpty)
        #expect(world.model.pendingSwitch == nil)
    }

    @Test func closeDiscardsCacheAndState() async throws {
        let world = try makeWorld()
        world.model.open()
        await settle(world.model)
        #expect(world.model.cache.count == 1)
        world.model.close()
        #expect(world.model.cache.count == 0)
        #expect(world.model.items.isEmpty)
        #expect(world.model.phase == .idle)
    }
}
