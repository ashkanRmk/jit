import Foundation
import GitTestKit
import Testing

@testable import Services

/// One-step Connect and the host-domain field (spec P8.accounts.1).
@MainActor @Suite struct AccountConnectTests {
    nonisolated static let gitlabUser =
        #"{"id":7,"username":"ada","name":"Ada L"}"#
    nonisolated static let gitlabToken =
        #"{"id":1,"scopes":["read_api","write_repository"],"expires_at":"2030-01-31"}"#
    nonisolated static let githubUser =
        #"{"id":42,"login":"octo","name":"Octo Cat"}"#

    struct Fixture {
        let store: ProfileStore
        let secrets = MemorySecretStore()
        let accounts: AccountsService

        @MainActor init(_ transport: ProviderStubTransport) {
            store = ProfileStore(location: TempLocation().location)
            accounts = AccountsService(profiles: store, secrets: secrets, location: TempLocation().location)
            accounts.transportOverride = { _ in transport }
        }
    }

    static func gitlabStub(status: Int = 200) -> ProviderStubTransport {
        ProviderStubTransport { request in
            if status != 200 { return .json(#"{"message":"401 Unauthorized"}"#, status: status) }
            return .json(request.url?.path.hasSuffix("/user") == true ? gitlabUser : gitlabToken)
        }
    }

    @Test func hostDomainAcceptsBareHostsAndHTTPSOnly() {
        #expect(HostDomain.webBaseURL("git.corp.example")?.absoluteString == "https://git.corp.example")
        #expect(HostDomain.webBaseURL(" https://Git.Corp.Example/ ")?.absoluteString == "https://git.corp.example")
        #expect(
            HostDomain.webBaseURL("git.corp.example:8443/gitlab/")?.absoluteString
                == "https://git.corp.example:8443/gitlab")
        #expect(HostDomain.webBaseURL("https://git.corp.example:443")?.absoluteString == "https://git.corp.example")
        for bad in [
            "", "   ", "http://git.corp.example", "ssh://git.corp.example", "https://user:pw@git.corp.example",
            "git.corp.example?x=1", "git corp.example", "-oProxyCommand=x.example", "nodots", "https://",
            "git.corp.example:99999", "git.corp.example#frag",
        ] {
            #expect(HostDomain.webBaseURL(bad) == nil, "\(bad)")
        }
    }

    @Test func selfManagedGitLabConnectsInOneStepAndCreatesTheServer() async throws {
        let transport = Self.gitlabStub()
        let fixture = Fixture(transport)
        let result = await fixture.accounts.connect(
            tab: .gitlabSelfManaged, host: "git.corp.example/gitlab", token: SecretBytes(utf8: "glpat-secret"))
        let account = try result.get()
        #expect(account.login == "ada")
        #expect(account.method == .pat)
        #expect(account.scopes == ["read_api", "write_repository"])
        #expect(account.status == .ok)
        let instance = try #require(fixture.store.customInstances.first)
        #expect(fixture.store.customInstances.count == 1)
        #expect(instance.kind == .gitlab)
        #expect(instance.name == "git.corp.example")
        #expect(instance.sshHost == "git.corp.example")
        #expect(account.instanceID == instance.id)
        #expect(fixture.store.accounts == [account])
        #expect(providerSecretText(try await fixture.secrets.read(.account(account.id))) == "glpat-secret")
        let first = try #require(transport.requests.first)
        #expect(first.url?.absoluteString == "https://git.corp.example/gitlab/api/v4/user")
        #expect(first.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-secret")
    }

    @Test func gitHubEnterpriseUsesTheV3APIOnTheHost() async throws {
        let transport = ProviderStubTransport { _ in
            .json(Self.githubUser, headers: ["X-OAuth-Scopes": "repo, read:org"])
        }
        let fixture = Fixture(transport)
        let account = try await fixture.accounts.connect(
            tab: .githubEnterprise, host: "https://ghe.corp.example", token: SecretBytes(utf8: "ghp_secret")
        ).get()
        #expect(account.login == "octo")
        #expect(account.scopes == ["repo", "read:org"])
        let instance = try #require(fixture.store.instance(account.instanceID))
        #expect(instance.kind == .github)
        #expect(instance.isSelfManaged)
        #expect(AccountTab.tab(for: instance) == .githubEnterprise)
        #expect(transport.requests.map { $0.url?.absoluteString } == ["https://ghe.corp.example/api/v3/user"])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret")
        // The server survives a reload of profiles.json.
        fixture.store.flush()
    }

    @Test func rejectedTokenSavesNothing() async {
        let fixture = Fixture(Self.gitlabStub(status: 401))
        let result = await fixture.accounts.connect(
            tab: .gitlabSelfManaged, host: "git.corp.example", token: SecretBytes(utf8: "bad"))
        #expect(result == .failure(.rejected(server: "git.corp.example")))
        #expect(fixture.store.accounts.isEmpty)
        #expect(fixture.store.customInstances.isEmpty)
    }

    @Test func invalidHostAndEmptyTokenNeverReachTheNetwork() async {
        let transport = Self.gitlabStub()
        let fixture = Fixture(transport)
        let badHost = await fixture.accounts.connect(
            tab: .gitlabSelfManaged, host: "http://git.corp.example", token: SecretBytes(utf8: "t"))
        #expect(badHost == .failure(.invalidHost))
        let wrongFamily = await fixture.accounts.connect(
            tab: .gitlabSelfManaged, host: "github.com", token: SecretBytes(utf8: "t"))
        #expect(wrongFamily == .failure(.invalidHost))
        let empty = await fixture.accounts.connect(tab: .gitlab, token: SecretBytes(utf8: ""))
        #expect(empty == .failure(.emptyToken))
        #expect(transport.requests.isEmpty)
        #expect(fixture.store.customInstances.isEmpty)
    }

    @Test func connectingTheSameUserAgainReusesServerAndAccount() async throws {
        let fixture = Fixture(Self.gitlabStub())
        let first = try await fixture.accounts.connect(
            tab: .gitlabSelfManaged, host: "git.corp.example", token: SecretBytes(utf8: "one")
        ).get()
        let second = try await fixture.accounts.connect(
            tab: .gitlabSelfManaged, host: "https://GIT.corp.example/", token: SecretBytes(utf8: "two")
        ).get()
        #expect(second.id == first.id)
        #expect(fixture.store.customInstances.count == 1)
        #expect(fixture.store.accounts.count == 1)
        #expect(providerSecretText(try await fixture.secrets.read(.account(first.id))) == "two")
    }

    @Test func saasTabsUseTheBuiltInServers() async throws {
        let transport = Self.gitlabStub()
        let fixture = Fixture(transport)
        let account = try await fixture.accounts.connect(tab: .gitlab, token: SecretBytes(utf8: "t")).get()
        #expect(account.instanceID == .gitlab)
        #expect(fixture.store.customInstances.isEmpty)
        #expect(transport.requests.first?.url?.absoluteString == "https://gitlab.com/api/v4/user")
        #expect(fixture.accounts.connectInstance(tab: .gitlabSelfManaged, host: "gitlab.com")?.id == .gitlab)
        #expect(fixture.accounts.connectInstance(tab: .githubEnterprise, host: "github.com")?.id == .github)
    }

    @Test func replacingRequiresTheSameUser() async throws {
        let fixture = Fixture(Self.gitlabStub())
        let other = HostingAccount(instanceID: .gitlab, login: "grace", userID: "99", method: .pat)
        let result = await fixture.accounts.connect(
            instance: .gitlab, token: SecretBytes(utf8: "t"), replacing: other)
        #expect(result == .failure(.differentUser(found: "ada", expected: "grace")))
        #expect(fixture.store.accounts.isEmpty)
    }

    @Test func tabsCoverEveryInstance() {
        #expect(AccountTab.tab(for: .github) == .github)
        #expect(AccountTab.tab(for: .gitlab) == .gitlab)
        #expect(AccountTab.allCases.map(\.title) == ["GitHub", "GitHub Enterprise", "GitLab", "GitLab Self-Managed"])
        #expect(AccountTab.allCases.filter(\.isSelfHosted) == [.githubEnterprise, .gitlabSelfManaged])
    }
}
