import Foundation
import Synchronization
import Testing

@testable import Services

/// Records requested sleeps instead of sleeping; advances the test clock by the same amount.
final class RecordingSleeper: Sendable {
    let durations = Mutex<[Duration]>([])
    let clock: ProviderTestClock
    let cancelAfter: Int?

    init(clock: ProviderTestClock, cancelAfter: Int? = nil) {
        self.clock = clock
        self.cancelAfter = cancelAfter
    }

    var seconds: [Int64] { durations.withLock { $0.map(\.components.seconds) } }

    var closure: @Sendable (Duration) async throws -> Void {
        { duration in
            let count = self.durations.withLock { list in
                list.append(duration)
                return list.count
            }
            if let limit = self.cancelAfter, count > limit { throw CancellationError() }
            self.clock.advance(TimeInterval(duration.components.seconds))
        }
    }
}

@Suite struct DeviceFlowProviderTests {
    static let start = ProviderStubResponse.json(
        #"{"device_code":"3584d83530557fdd1f46af8289938c8ef79f9dc5","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    )

    func flow(_ transport: ProviderStubTransport, sleeper: RecordingSleeper, clock: ProviderTestClock)
        -> GitHubDeviceFlow
    {
        GitHubDeviceFlow(clientID: "Iv1.abc", transport: transport, sleep: sleeper.closure, now: clock.closure)
    }

    @Test func startParsesAndSendsClientIDAndScopes() async throws {
        let clock = ProviderTestClock()
        let transport = ProviderStubTransport { _ in Self.start }
        let authorization = try await flow(transport, sleeper: RecordingSleeper(clock: clock), clock: clock).start()
        #expect(authorization.userCode == "WDJB-MJHT")
        #expect(authorization.verificationURL.absoluteString == "https://github.com/login/device")
        #expect(authorization.interval == 5)
        #expect(authorization.expiresAt == clock.now.addingTimeInterval(900))
        #expect(!authorization.description.contains("3584d835"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(providerForm(request) == ["client_id": "Iv1.abc", "scope": "repo read:org"])
    }

    @Test func startRejectsForeignVerificationURL() async throws {
        let clock = ProviderTestClock()
        let transport = ProviderStubTransport { _ in
            .json(
                #"{"device_code":"d","user_code":"U","verification_uri":"https://evil.example/login/device","expires_in":900,"interval":5}"#
            )
        }
        await #expect(throws: OAuthError.invalidResponse) {
            try await flow(transport, sleeper: RecordingSleeper(clock: clock), clock: clock).start()
        }
    }

    @Test func deviceFlowRespectsIntervalAndSlowDown() async throws {
        let clock = ProviderTestClock()
        let sleeper = RecordingSleeper(clock: clock)
        let transport = ProviderStubTransport(sequence: [
            Self.start,
            .json(#"{"error":"authorization_pending","error_description":"pending"}"#),
            .json(#"{"error":"slow_down","error_description":"Too many requests","interval":10}"#),
            .json(#"{"error":"authorization_pending"}"#),
            .json(#"{"error":"slow_down"}"#),
            .json(
                #"{"access_token":"gho_16C7e42F292c6912E7710c838347Ae178B4a","token_type":"bearer","scope":"repo,read:org"}"#
            ),
        ])
        let github = flow(transport, sleeper: sleeper, clock: clock)
        let authorization = try await github.start()
        let tokens = try await github.poll(authorization)
        #expect(providerSecretText(tokens.access) == "gho_16C7e42F292c6912E7710c838347Ae178B4a")
        #expect(tokens.refresh == nil)
        #expect(tokens.expiresAt == nil)
        #expect(tokens.scopes == ["repo", "read:org"])
        // 5 → pending → 5 → slow_down (max(5+5, 10)) → 10 → pending → 10 → slow_down (+5) → 15 → success.
        #expect(sleeper.seconds == [5, 5, 10, 10, 15])
        let poll = try #require(transport.requests.last)
        #expect(poll.url?.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(
            providerForm(poll) == [
                "client_id": "Iv1.abc", "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
        #expect(providerForm(poll)["client_secret"] == nil)
    }

    @Test func terminalErrors() async throws {
        for (body, expected) in [
            (#"{"error":"expired_token"}"#, OAuthError.expired),
            (#"{"error":"access_denied"}"#, OAuthError.cancelled),
            (#"{"error":"device_flow_disabled"}"#, OAuthError.provider(code: "device_flow_disabled")),
        ] {
            let clock = ProviderTestClock()
            let transport = ProviderStubTransport(sequence: [Self.start, .json(body)])
            let github = flow(transport, sleeper: RecordingSleeper(clock: clock), clock: clock)
            let authorization = try await github.start()
            await #expect(throws: expected) { try await github.poll(authorization) }
        }
    }

    @Test func stopsAtLocalExpiryWithoutPolling() async throws {
        let clock = ProviderTestClock()
        let transport = ProviderStubTransport(sequence: [
            .json(
                #"{"device_code":"d","user_code":"U","verification_uri":"https://github.com/login/device","expires_in":3,"interval":5}"#
            )
        ])
        let github = flow(transport, sleeper: RecordingSleeper(clock: clock), clock: clock)
        let authorization = try await github.start()
        await #expect(throws: OAuthError.expired) { try await github.poll(authorization) }
        #expect(transport.requests.count == 1)
    }

    @Test func cancellationStopsPolling() async throws {
        let clock = ProviderTestClock()
        let sleeper = RecordingSleeper(clock: clock, cancelAfter: 2)
        let transport = ProviderStubTransport(sequence: [Self.start, .json(#"{"error":"authorization_pending"}"#)])
        let github = flow(transport, sleeper: sleeper, clock: clock)
        let authorization = try await github.start()
        await #expect(throws: CancellationError.self) { try await github.poll(authorization) }
        #expect(transport.requests.count == 3)  // start + 2 polls, nothing after cancellation

        // A cancelled Task with the real sleeper stops immediately.
        let real = GitHubDeviceFlow(clientID: "Iv1.abc", transport: transport)
        let task = Task { try await real.poll(authorization) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests.count == 3)
    }
}
