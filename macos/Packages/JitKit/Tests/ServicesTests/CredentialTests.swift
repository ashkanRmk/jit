import Foundation
import GitCore
import GitTestKit
import Security
import Synchronization
import Testing

@testable import Services

/// Finds the helper binary SwiftPM built next to the test bundle.
enum HelperBinary {
    final class Marker {}

    static var path: String? {
        let directory = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        for name in ["jit-git-helper", "JitGitHelper"] {
            let candidate = directory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// A credential source with fixed answers that records calls.
final class FakeCredentialSource: CredentialSource {
    let token: [UInt8]
    let username: String
    let calls = Mutex<[String]>([])

    init(token: String, username: String = "ada") {
        self.token = Array(token.utf8)
        self.username = username
    }

    func httpsCredential(accountID: HostingAccountID, host: String) async throws(CredentialError) -> SecretPair {
        calls.withLock { $0.append("https \(host)") }
        return SecretPair(username: username, secret: SecretBytes(token))
    }

    func sshPassphrase(keyPath: String, fingerprint: String?, prompt: String) async throws(CredentialError)
        -> SecretBytes
    {
        calls.withLock { $0.append("passphrase \(keyPath)") }
        return SecretBytes(token)
    }

    func proxyCredential(proxyID: ProxyConfigID, username: String) async throws(CredentialError) -> SecretPair {
        calls.withLock { $0.append("proxy \(proxyID.rawValue)") }
        return SecretPair(username: username, secret: SecretBytes(token))
    }

    func credentialRejected(accountID: HostingAccountID, host: String) async {
        calls.withLock { $0.append("rejected \(host)") }
    }

    func credentialAccepted(accountID: HostingAccountID, host: String) async {
        calls.withLock { $0.append("accepted \(host)") }
    }
}

@Suite struct SecretTests {
    @Test func secretDescriptionIsRedacted() {
        let secret = SecretBytes(utf8: "ghp_SENTINEL")
        #expect("\(secret)" == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
        #expect(!"\(SecretPair(username: "u", secret: secret))".contains("SENTINEL"))
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test func secretBufferWipedOnDeinit() {
        // The hook is process-wide and other suites create secrets in parallel: look for this buffer's wipe.
        let observed = Mutex<[[UInt8]]>([])
        SecretBytes.wipeObserver = { buffer in observed.withLock { $0.append(Array(buffer)) } }
        defer { SecretBytes.wipeObserver = nil }
        do { _ = SecretBytes(utf8: "wipe-me-please") }
        let wipes = observed.withLock { $0 }
        #expect(wipes.contains { $0.count == 14 && $0.allSatisfy { $0 == 0 } })
        #expect(wipes.allSatisfy { buffer in buffer.allSatisfy { $0 == 0 } })
    }

    @Test func memoryStoreRoundTrip() async throws {
        let store = MemorySecretStore()
        let reference = SecretReference.account(.new())
        try await store.store(SecretBytes(utf8: "one"), for: reference, label: "l")
        #expect(try await store.read(reference).dataCopy() == Data("one".utf8))
        try await store.delete(reference)
        await #expect(throws: KeychainError.notFound) { try await store.read(reference) }
    }
}

/// Real login-keychain round trip under a throwaway service prefix (items deleted afterwards).
@Suite(.serialized) struct KeychainStoreTests {
    let store = KeychainStore(servicePrefix: "com.ashkanrmk.jit.tests.\(UUID().uuidString.prefix(8))")

    @Test func roundTripOverwriteDeleteAndAttributes() async throws {
        let reference = SecretReference.account(.new())
        defer { Task { try? await store.delete(reference) } }
        try await store.store(SecretBytes(utf8: "first"), for: reference, label: "Jit — test")
        #expect(try await store.read(reference).dataCopy() == Data("first".utf8))
        try await store.store(SecretBytes(utf8: "second"), for: reference, label: "Jit — test")
        #expect(try await store.read(reference).dataCopy() == Data("second".utf8))
        #expect(await store.exists(reference))
        let attributes = try #require(store.attributes(reference))
        if store.useDataProtection {
            // The file-based login keychain (unsigned dev/test builds) doesn't report accessibility classes.
            #expect(
                attributes[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
        #expect((attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
        try await store.delete(reference)
        #expect(!(await store.exists(reference)))
        await #expect(throws: KeychainError.notFound) { try await store.read(reference) }
    }
}

@Suite(.serialized) struct BrokerHelperTests {
    static let sentinel = "jit-SENTINEL-7f3a9c"

    /// Runs `git credential fill` with Jit's remote configuration: proves the helper path end to end through Git's
    /// own credential machinery (shell, helper protocol), and that inherited helpers are never consulted.
    func credentialFill(
        host: String, broker: CredentialBroker, helper: String, repoHelperLog: String? = nil
    ) async throws -> String {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        if let repoHelperLog {
            // A "system/global" style helper that records every call — must never run.
            _ = try await repo.git("config", "credential.helper", "!f() { echo called >> '\(repoHelperLog)'; }; f")
        }
        let access = RemoteAccess(helperPath: helper, broker: broker.endpoint, httpsCredentials: true)
        let options = GitEnvironment.remoteConfiguration(access)
        let engine = sandbox.engine
        var command = GitCommand(
            options + ["credential", "fill"], in: repo.path, kind: .read,
            stdin: Array("protocol=https\nhost=\(host)\n\n".utf8))
        command.environment = GitEnvironment.remoteVariables(access)
        command.acceptedExitCodes = [0, 128]
        let output = try await engine.run(command)
        return output.stdoutText + output.stderrText
    }

    @Test func helperReturnsCredentialForExpectedHost() async throws {
        let helper = try #require(HelperBinary.path)
        let account = HostingAccountID.new()
        let source = FakeCredentialSource(token: Self.sentinel)
        let broker = try CredentialBroker(
            policy: BrokerPolicy(https: [.init(accountID: account, host: "github.com", port: 443)]), source: source,
            expectedPeer: helper)
        defer { broker.shutdown() }
        let log = NSTemporaryDirectory() + "jit-helper-calls-\(UUID().uuidString)"
        let output = try await credentialFill(host: "github.com", broker: broker, helper: helper, repoHelperLog: log)
        #expect(output.contains("username=ada"))
        #expect(output.contains("password=\(Self.sentinel)"))
        #expect(source.calls.withLock { $0 } == ["https github.com"])
        #expect(!FileManager.default.fileExists(atPath: log), "inherited credential helper was consulted")
    }

    @Test func helperRefusesUnexpectedHost() async throws {
        let helper = try #require(HelperBinary.path)
        let source = FakeCredentialSource(token: Self.sentinel)
        let broker = try CredentialBroker(
            policy: BrokerPolicy(https: [.init(accountID: .new(), host: "github.com", port: 443)]), source: source,
            expectedPeer: helper)
        defer { broker.shutdown() }
        let output = try await credentialFill(host: "evil.example", broker: broker, helper: helper)
        #expect(!output.contains(Self.sentinel))
        #expect(source.calls.withLock { $0 }.isEmpty)
        #expect(broker.refusals.withLock { $0 }.contains("unexpected host evil.example"))
        // Same host, different port → refused too.
        let other = try await credentialFill(host: "github.com:8443", broker: broker, helper: helper)
        #expect(!other.contains(Self.sentinel))
    }

    @Test func brokerRejectsWrongNonceAndForeignPeer() async throws {
        let helper = try #require(HelperBinary.path)
        let source = FakeCredentialSource(token: Self.sentinel)
        let policy = BrokerPolicy(https: [.init(accountID: .new(), host: "github.com", port: 443)])
        // Wrong nonce: same socket, forged nonce.
        let broker = try CredentialBroker(policy: policy, source: source, expectedPeer: helper)
        defer { broker.shutdown() }
        let forged = try await runHelper(
            helper,
            broker: BrokerEndpoint(socketPath: broker.endpoint.socketPath, nonce: String(repeating: "0", count: 64)))
        #expect(!forged.contains(Self.sentinel))
        #expect(broker.refusals.withLock { $0 }.contains("bad nonce"))
        // Foreign peer: a broker expecting another executable drops the real helper's connection.
        let strict = try CredentialBroker(policy: policy, source: source, expectedPeer: "/usr/bin/true")
        defer { strict.shutdown() }
        let dropped = try await runHelper(helper, broker: strict.endpoint)
        #expect(!dropped.contains(Self.sentinel))
        #expect(strict.refusals.withLock { $0 }.contains("unexpected peer process"))
    }

    @Test func brokerIsOperationScopedAndCleansUp() async throws {
        let broker = try CredentialBroker(
            policy: BrokerPolicy(), source: FakeCredentialSource(token: "x"), expectedPeer: nil)
        let path = broker.endpoint.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: path))
        broker.shutdown()
        #expect(!FileManager.default.fileExists(atPath: directory))
        broker.shutdown()  // idempotent
    }

    @Test func eraseMarksAccountRejected() async throws {
        let helper = try #require(HelperBinary.path)
        let source = FakeCredentialSource(token: Self.sentinel)
        let broker = try CredentialBroker(
            policy: BrokerPolicy(https: [.init(accountID: .new(), host: "github.com", port: 443)]), source: source,
            expectedPeer: helper)
        defer { broker.shutdown() }
        _ = try await runHelper(helper, broker: broker.endpoint, action: "erase")
        #expect(source.calls.withLock { $0 } == ["rejected github.com"])
    }

    @Test func askpassAnswersOnlyTheExpectedKeyPassphrase() async throws {
        let helper = try #require(HelperBinary.path)
        let source = FakeCredentialSource(token: Self.sentinel)
        let broker = try CredentialBroker(
            policy: BrokerPolicy(sshKey: .init(path: "/keys/id ed25519", fingerprint: "SHA256:x")), source: source,
            expectedPeer: helper)
        defer { broker.shutdown() }
        let good = try await runAskpass(
            helper, broker: broker.endpoint, prompt: "Enter passphrase for key '/keys/id ed25519': ")
        #expect(good.trimmingCharacters(in: .newlines) == Self.sentinel)
        let otherKey = try await runAskpass(
            helper, broker: broker.endpoint, prompt: "Enter passphrase for key '/keys/other': ")
        #expect(otherKey.isEmpty)
        let yesNo = try await runAskpass(
            helper, broker: broker.endpoint,
            prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        #expect(yesNo.isEmpty)
        #expect(source.calls.withLock { $0 } == ["passphrase /keys/id ed25519"])
    }

    @Test func secretNeverInArgvOrEnv() async throws {
        let helper = try #require(HelperBinary.path)
        let seen = Mutex<[String]>([])
        ProcessRunner.spawnObserver.withLock { observer in
            observer = { spec in
                seen.withLock {
                    $0.append(
                        (spec.arguments + spec.environment.map { "\($0.key)=\($0.value)" }).joined(separator: " "))
                }
            }
        }
        defer { ProcessRunner.spawnObserver.withLock { $0 = nil } }
        let source = FakeCredentialSource(token: Self.sentinel)
        let broker = try CredentialBroker(
            policy: BrokerPolicy(https: [.init(accountID: .new(), host: "github.com", port: 443)]), source: source,
            expectedPeer: helper)
        defer { broker.shutdown() }
        let output = try await credentialFill(host: "github.com", broker: broker, helper: helper)
        #expect(output.contains(Self.sentinel))  // it reached Git through the helper's stdout…
        let spawned = seen.withLock { $0 }
        #expect(!spawned.isEmpty)
        #expect(spawned.allSatisfy { !$0.contains(Self.sentinel) })  // …and never through argv or environment.
    }

    // MARK: helpers

    func runHelper(_ helper: String, broker: BrokerEndpoint, action: String = "get") async throws -> String {
        let spec = ProcessSpec(
            executable: helper, arguments: ["credential", action], workingDirectory: NSTemporaryDirectory(),
            environment: ["JIT_BROKER_SOCKET": broker.socketPath, "JIT_BROKER_NONCE": broker.nonce],
            timeout: .seconds(20), acceptedExitCodes: [0, 1], stdin: Array("protocol=https\nhost=github.com\n\n".utf8))
        return try await ProcessRunner().run(spec).stdoutText
    }

    func runAskpass(_ helper: String, broker: BrokerEndpoint, prompt: String) async throws -> String {
        let spec = ProcessSpec(
            executable: helper, arguments: [prompt], workingDirectory: NSTemporaryDirectory(),
            environment: [
                "JIT_HELPER_MODE": "askpass", "JIT_BROKER_SOCKET": broker.socketPath, "JIT_BROKER_NONCE": broker.nonce,
            ], timeout: .seconds(20), acceptedExitCodes: [0, 1])
        return try await ProcessRunner().run(spec).stdoutText
    }
}
