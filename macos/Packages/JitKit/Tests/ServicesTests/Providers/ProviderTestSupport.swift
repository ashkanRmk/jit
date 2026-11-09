import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import Services

/// A canned HTTP response.
struct ProviderStubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data = Data()

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> ProviderStubResponse {
        var all = ["Content-Type": "application/json"]
        all.merge(headers) { $1 }
        return ProviderStubResponse(status: status, headers: all, body: Data(text.utf8))
    }
}

struct ProviderStubFailure: Error {}

/// An `HTTPTransport` that records every request and answers from a handler (recorded-fixture JSON inline).
final class ProviderStubTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> ProviderStubResponse

    private let handler: Handler
    private let recorded = Mutex<[URLRequest]>([])

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Answers the given responses in order (the last one repeats).
    convenience init(sequence: [ProviderStubResponse]) {
        let index = Locked(0)
        self.init { _ in
            index.withLock { value in
                defer { value += 1 }
                return sequence[min(value, sequence.count - 1)]
            }
        }
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let stub = try handler(request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else { throw ProviderStubFailure() }
        return (stub.body, response)
    }
}

/// A fixed, settable clock.
final class ProviderTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var closure: @Sendable () -> Date { { self.now } }
}

func providerURL(_ text: String) throws -> URL { try #require(URL(string: text)) }

func providerQuery(_ request: URLRequest) -> [String: String] {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return [:]
    }
    var items: [String: String] = [:]
    for item in components.queryItems ?? [] { items[item.name] = item.value ?? "" }
    return items
}

/// Decodes an `application/x-www-form-urlencoded` request body.
func providerForm(_ request: URLRequest) -> [String: String] {
    guard let body = request.httpBody else { return [:] }
    var fields: [String: String] = [:]
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        let key = parts[0].removingPercentEncoding ?? parts[0]
        let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        fields[key] = value
    }
    return fields
}

func providerSecretText(_ secret: SecretBytes) -> String { String(decoding: secret.dataCopy(), as: UTF8.self) }
