import Foundation
import GitCore
import Testing

@testable import Services

@MainActor @Suite struct ProfilesV2Tests {
    static let ada = GitIdentity(name: "Ada Lovelace", email: "ada@example.com")
    static let env = AccessEnvironment(
        userKnownHosts: "/Users/me/.ssh/known_hosts", jitKnownHosts: "/tmp/jit/known_hosts", caDirectory: "/tmp/jit/ca",
        agentAvailable: true)

    @Test func migrationFromIdentityOnlyV1() throws {
        let temp = TempLocation()
        let id = UUID()
        let v1 = """
            {"version":1,"activeProfileID":"\(id.uuidString)","profiles":[{"id":"\(id.uuidString)","displayName":"Work",
            "colorIndex":2,"author":{"name":"Ada Lovelace","email":"ada@example.com"}}]}
            """
        try StoreLocation(directory: temp.location.directory).ensureDirectory()
        try Data(v1.utf8).write(to: temp.location.url("profiles.json"))
        let store = ProfileStore(location: temp.location)
        #expect(store.loadedVersion == 1)
        #expect(store.profiles.count == 1)
        #expect(store.activeProfile?.displayName == "Work")
        #expect(store.activeProfile?.auth == nil)
        #expect(store.accounts.isEmpty)
        store.flush()
        let rewritten = try String(contentsOf: temp.location.url("profiles.json"), encoding: .utf8)
        #expect(rewritten.contains("\"version\" : 2"))
        #expect(ProfileStore(location: temp.location).loadedVersion == 2)
    }

    @Test func unknownVersionIsBackedUpNotLost() throws {
        let temp = TempLocation()
        try StoreLocation(directory: temp.location.directory).ensureDirectory()
        try Data(#"{"version":99,"profiles":[]}"#.utf8).write(to: temp.location.url("profiles.json"))
        let store = ProfileStore(location: temp.location)
        #expect(store.profiles.isEmpty)
        #expect(temp.files.contains { $0.hasPrefix("profiles.json.bak-") })
    }

    @Test func accountsInstancesAndNetworkRoundTrip() {
        let temp = TempLocation()
        let store = ProfileStore(location: temp.location)
        let instance = ProviderInstance(
            id: .new(), kind: .gitlab, name: "Corp", webBaseURL: URL(string: "https://git.corp.example:8443/gitlab")!,
            sshHost: "git.corp.example", sshPort: 2222, caCertificateIDs: ["abc"],
            proxy: .manual(ManualProxy(kind: .http, host: "proxy.corp", port: 3128, username: "u")))
        store.upsertInstance(instance)
        let account = HostingAccount(instanceID: instance.id, login: "ada", userID: "7", method: .pat)
        store.addAccount(account)
        store.create(
            GitProfile(
                displayName: "Work", colorIndex: 0, author: Self.ada,
                auth: ProfileAuth(instanceID: instance.id, accountID: account.id)))
        store.setNetwork(GlobalNetworkConfig(proxy: .direct))
        store.flush()
        let reloaded = ProfileStore(location: temp.location)
        #expect(reloaded.customInstances == [instance])
        #expect(reloaded.accounts == [account])
        #expect(reloaded.network.proxy == .direct)
        #expect(reloaded.snapshot()?.account == account)
        #expect(reloaded.snapshot()?.instance == instance)
    }

    @Test func removingAccountDetachesProfilesButKeepsIdentity() {
        let store = ProfileStore(location: TempLocation().location)
        let account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        store.addAccount(account)
        store.create(
            GitProfile(
                displayName: "P", colorIndex: 0, author: Self.ada,
                auth: ProfileAuth(instanceID: .github, accountID: account.id, ssh: .agent)))
        store.removeAccount(account.id)
        #expect(store.activeProfile?.auth?.accountID == nil)
        #expect(store.activeProfile?.auth?.ssh == .agent)
        #expect(store.activeProfile?.author == Self.ada)
    }

    // MARK: Snapshot resolution (design §4.2)

    func githubSnapshot(account: HostingAccount, ssh: SSHIdentity? = nil) -> ProfileSnapshot {
        let profile = GitProfile(
            displayName: "Personal", colorIndex: 0, author: Self.ada,
            auth: ProfileAuth(instanceID: .github, accountID: account.id, ssh: ssh))
        return ProfileSnapshot(profile, account: account, instance: .github)
    }

    @Test func snapshotHTTPSMatchingInstance() {
        let account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        let resolution = AccessResolver.resolve(
            urls: ["https://github.com/acme/app.git"], snapshot: githubSnapshot(account: account),
            environment: Self.env)
        #expect(
            resolution.policy.https == [BrokerPolicy.HTTPSTarget(accountID: account.id, host: "github.com", port: 443)])
        #expect(resolution.mismatches.isEmpty)
        #expect(resolution.usesHTTPSCredentials)
    }

    @Test func snapshotHTTPSNoAccountForHostIsAnonymousWithMismatch() {
        let account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        let resolution = AccessResolver.resolve(
            urls: ["https://gitlab.corp.example/team/app.git"], snapshot: githubSnapshot(account: account),
            environment: Self.env)
        #expect(resolution.policy.https.isEmpty)
        #expect(resolution.mismatches == [.noAccountForHost(host: "gitlab.corp.example")])
        #expect(!resolution.usesHTTPSCredentials)
    }

    @Test func snapshotSSHUsesProfileKeyOnly() {
        let account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        let snapshot = githubSnapshot(
            account: account, ssh: .keyFile(path: "/Users/me/keys/oss key", fingerprint: "SHA256:abc"))
        let resolution = AccessResolver.resolve(
            urls: ["git@github.com:acme/app.git"], snapshot: snapshot, environment: Self.env)
        #expect(resolution.ssh?.keyPath == "/Users/me/keys/oss key")
        #expect(resolution.ssh?.strictConfig == true)
        #expect(resolution.ssh?.knownHostsFiles == [Self.env.userKnownHosts, Self.env.jitKnownHosts])
        #expect(resolution.policy.sshKey?.path == "/Users/me/keys/oss key")
        #expect(resolution.policy.https.isEmpty)
        // A different SSH host keeps the profile's key but flags the mismatch.
        let other = AccessResolver.resolve(
            urls: ["ssh://git@gitlab.com/acme/app.git"], snapshot: snapshot, environment: Self.env)
        #expect(other.ssh?.keyPath == "/Users/me/keys/oss key")
        #expect(other.mismatches == [.sshHostNotInstance(host: "gitlab.com")])
    }

    @Test func snapshotImmutableAfterProfileEdit() {
        let store = ProfileStore(location: TempLocation().location)
        let account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        store.addAccount(account)
        var profile = GitProfile(
            displayName: "P", colorIndex: 0, author: Self.ada,
            auth: ProfileAuth(instanceID: .github, accountID: account.id))
        store.create(profile)
        let snapshot = store.snapshot()
        profile.author = GitIdentity(name: "Grace", email: "grace@example.com")
        profile.auth = nil
        store.update(profile)
        store.setActive(nil)
        #expect(snapshot?.author == Self.ada)
        #expect(snapshot?.auth?.accountID == account.id)
        #expect(snapshot?.account == account)
    }

    @Test func twoAccountsSameHostSelectedByID() {
        let personal = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        let oss = HostingAccount(instanceID: .github, login: "ada-oss", userID: "2", method: .pat)
        let first = AccessResolver.resolve(
            urls: ["https://github.com/acme/app"], snapshot: githubSnapshot(account: personal), environment: Self.env)
        let second = AccessResolver.resolve(
            urls: ["https://github.com/acme/app"], snapshot: githubSnapshot(account: oss), environment: Self.env)
        #expect(first.policy.https.first?.accountID == personal.id)
        #expect(second.policy.https.first?.accountID == oss.id)
    }

    @Test func selfManagedPathPrefixAndPortMatch() {
        let instance = ProviderInstance(
            id: .new(), kind: .gitlab, name: "Corp", webBaseURL: URL(string: "https://git.corp.example:8443/gitlab")!,
            sshHost: "git.corp.example", sshPort: 2222, caCertificateIDs: ["ca1"])
        #expect(instance.apiBaseURL.absoluteString == "https://git.corp.example:8443/gitlab/api/v4")
        #expect(instance.gitURLPrefix == "https://git.corp.example:8443/gitlab/")
        #expect(instance.matchesHTTPS(host: "git.corp.example", port: 8443, path: "/gitlab/team/app.git"))
        #expect(!instance.matchesHTTPS(host: "git.corp.example", port: 8443, path: "/other/app.git"))
        #expect(!instance.matchesHTTPS(host: "git.corp.example", port: 443, path: "/gitlab/team/app.git"))
        #expect(instance.matchesSSH(host: "GIT.corp.example", port: 2222))
        let account = HostingAccount(instanceID: instance.id, login: "ada", userID: "1", method: .pat)
        let profile = GitProfile(
            displayName: "W", colorIndex: 0, author: Self.ada,
            auth: ProfileAuth(instanceID: instance.id, accountID: account.id))
        let resolution = AccessResolver.resolve(
            urls: ["https://git.corp.example:8443/gitlab/team/app.git"],
            snapshot: ProfileSnapshot(profile, account: account, instance: instance), environment: Self.env)
        #expect(
            resolution.network == [
                ScopedNetwork(urlPrefix: "https://git.corp.example:8443/", caInfo: "/tmp/jit/ca/ca1.pem")
            ])
        #expect(resolution.policy.https.first?.port == 8443)
    }

    @Test func serverCAAppliesToProfilesWithoutAccountButNoCredentials() {
        let instance = ProviderInstance(
            id: .new(), kind: .gitlab, name: "Corp", webBaseURL: URL(string: "https://git.corp.example")!,
            sshHost: "git.corp.example", caCertificateIDs: ["ca1"])
        let profile = GitProfile(displayName: "Personal", colorIndex: 0, author: Self.ada)
        let resolution = AccessResolver.resolve(
            urls: ["https://git.corp.example/team/app.git"],
            snapshot: ProfileSnapshot(profile, networkInstances: [instance]), environment: Self.env)
        #expect(resolution.network.first?.caInfo == "/tmp/jit/ca/ca1.pem")
        #expect(resolution.policy.https.isEmpty)
        #expect(resolution.mismatches == [.noProfileAuth])
    }

    @Test func manualProxyBecomesScopedProxyAndBrokerTarget() {
        let proxy = ManualProxy(kind: .http, host: "proxy.corp", port: 3128, username: "ada")
        let account = HostingAccount(instanceID: .github, login: "ada", userID: "1", method: .pat)
        let resolution = AccessResolver.resolve(
            urls: ["https://github.com/acme/app"], snapshot: githubSnapshot(account: account), environment: Self.env,
            proxyFor: { _, _ in ResolvedProxy(proxy: proxy, source: .manual) })
        #expect(
            resolution.network == [
                ScopedNetwork(urlPrefix: "https://github.com/", proxy: .url("http://ada@proxy.corp:3128"))
            ])
        #expect(resolution.policy.proxies.first?.host == "proxy.corp")
        // Only the (non-secret) username is in the proxy URL; the password comes from the broker.
        #expect(!resolution.network.description.contains(":secret"))
    }

    @Test func sharedSSHKeyAcrossGitHubAccountsIsFlagged() {
        let store = ProfileStore(location: TempLocation().location)
        let a = HostingAccount(instanceID: .github, login: "a", userID: "1", method: .pat)
        let b = HostingAccount(instanceID: .github, login: "b", userID: "2", method: .pat)
        store.addAccount(a)
        store.addAccount(b)
        let key = SSHIdentity.keyFile(path: "/k", fingerprint: "SHA256:same")
        store.create(
            GitProfile(
                displayName: "A", colorIndex: 0, author: Self.ada,
                auth: ProfileAuth(instanceID: .github, accountID: a.id, ssh: key)))
        store.create(
            GitProfile(
                displayName: "B", colorIndex: 1, author: Self.ada,
                auth: ProfileAuth(instanceID: .github, accountID: b.id, ssh: key)))
        #expect(store.sharedSSHKeyConflicts()["SHA256:same"]?.count == 2)
    }

    @Test func remoteURLParsing() {
        #expect(RemoteURL.parse("https://ada:secret@git.corp:8443/x.git")?.hasEmbeddedPassword == true)
        #expect(RemoteURL.parse("https://git.corp:8443/x.git")?.port == 8443)
        #expect(RemoteURL.parse("git@github.com:a/b.git")?.scheme == .ssh)
        #expect(RemoteURL.parse("ssh://git@host:2222/a/b")?.port == 2222)
        #expect(RemoteURL.parse("/tmp/repo")?.scheme == .file)
        #expect(RemoteURL.masked("https://ada:secret@host/x") == "https://•••@host/x")
        #expect(!RemoteURL.masked("https://ada:secret@host/x").contains("secret"))
    }
}

extension Array where Element == ScopedNetwork {
    var description: String { map { "\($0)" }.joined() }
}
