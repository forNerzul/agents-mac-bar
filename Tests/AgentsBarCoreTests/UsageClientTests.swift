import Foundation
import Testing
@testable import AgentsBarCore

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let recorded = Locked<[URLRequest]>([])
    private let respond: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(_ respond: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.respond = respond
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        return try respond(request)
    }
}

private let endpoint = URL(string: "https://example.test/api/oauth/usage")!
private let validBody = #"{"five_hour":{"utilization":37.0,"resets_at":"2026-01-01T00:00:00Z"}}"#

private func reply(
    _ status: Int,
    body: String = "",
    headers: [String: String] = [:]
) -> @Sendable (URLRequest) throws -> (Data, HTTPURLResponse) {
    { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
        )!
        return (Data(body.utf8), response)
    }
}

private func fetchError(_ transport: FakeTransport) async -> UsageClientError? {
    do {
        _ = try await UsageClient(transport: transport, endpoint: endpoint).fetch(accessToken: "fake-token")
        return nil
    } catch {
        return error
    }
}

private struct FakeCredentials: CredentialsLoading {
    let result: Result<ClaudeCredentials?, CredentialsError>

    func load() throws -> ClaudeCredentials? { try result.get() }
}

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func creds(expiresIn: TimeInterval?) -> ClaudeCredentials {
    ClaudeCredentials(
        accessToken: "fake-token",
        expiresAt: expiresIn.map { fixedNow.addingTimeInterval($0) },
        subscriptionType: "max"
    )
}

private func service(
    _ result: Result<ClaudeCredentials?, CredentialsError>,
    transport: FakeTransport
) -> LimitsService {
    LimitsService(
        credentials: FakeCredentials(result: result),
        client: UsageClient(transport: transport, endpoint: endpoint),
        now: { fixedNow }
    )
}

@Suite struct UsageClientTests {
    @Test func buildsAuthenticatedGetRequest() async throws {
        let transport = FakeTransport(reply(200, body: validBody))
        _ = try await UsageClient(transport: transport, endpoint: endpoint).fetch(accessToken: "fake-token")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "AgentsBar/\(AgentsBarCore.version)")
        #expect(request.timeoutInterval == 10)
    }

    @Test func okResponseReturnsSnapshot() async throws {
        let transport = FakeTransport(reply(200, body: validBody))
        let snapshot = try await UsageClient(transport: transport, endpoint: endpoint).fetch(accessToken: "fake-token")
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.limits[0].title == "Session (5-hour)")
        #expect(snapshot.limits[0].percent == 37)
    }

    @Test(arguments: [401, 403])
    func authFailuresAreUnauthorized(status: Int) async {
        #expect(await fetchError(FakeTransport(reply(status))) == .unauthorized)
    }

    @Test func rateLimitedParsesRetryAfter() async {
        let transport = FakeTransport(reply(429, headers: ["Retry-After": "120"]))
        #expect(await fetchError(transport) == .rateLimited(retryAfter: 120))
    }

    @Test func rateLimitedWithoutHeaderHasNoRetryAfter() async {
        #expect(await fetchError(FakeTransport(reply(429))) == .rateLimited(retryAfter: nil))
    }

    @Test func rateLimitedIgnoresNonNumericRetryAfter() async {
        let transport = FakeTransport(reply(429, headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]))
        #expect(await fetchError(transport) == .rateLimited(retryAfter: nil))
    }

    @Test func otherStatusIsHTTPError() async {
        #expect(await fetchError(FakeTransport(reply(500))) == .http(status: 500))
    }

    @Test func transportFailureIsTransportError() async {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        #expect(await fetchError(transport) == .transport)
    }

    @Test func badBodyIsParseError() async {
        let transport = FakeTransport(reply(200, body: "not json"))
        #expect(await fetchError(transport) == .parse(.invalidPayload))
    }

    @Test func emptyLimitsIsParseError() async {
        let transport = FakeTransport(reply(200, body: "{}"))
        #expect(await fetchError(transport) == .parse(.noLimits))
    }
}

@Suite struct LimitsServiceTests {
    @Test func noCredentialsIsSignedOut() async {
        let transport = FakeTransport(reply(200, body: validBody))
        #expect(await service(.success(nil), transport: transport).load() == .signedOut)
        #expect(transport.requests.isEmpty)
    }

    @Test func credentialsErrorIsCredentialsUnavailable() async {
        let transport = FakeTransport(reply(200, body: validBody))
        let state = await service(.failure(.keychain(-25293)), transport: transport).load()
        #expect(state == .credentialsUnavailable)
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [-3600.0, 0, 30, 60])
    func expiredOrWithinSkewSkipsNetwork(expiresIn: TimeInterval) async {
        let transport = FakeTransport(reply(200, body: validBody))
        let state = await service(.success(creds(expiresIn: expiresIn)), transport: transport).load()
        #expect(state == .expired)
        #expect(transport.requests.isEmpty)
    }

    @Test func unauthorizedFromServerIsExpired() async {
        let transport = FakeTransport(reply(401))
        let state = await service(.success(creds(expiresIn: 3600)), transport: transport).load()
        #expect(state == .expired)
        #expect(transport.requests.count == 1)
    }

    @Test func validTokenReturnsSnapshot() async throws {
        let transport = FakeTransport(reply(200, body: validBody))
        let state = await service(.success(creds(expiresIn: 61)), transport: transport).load()
        guard case .ok(let snapshot) = state else {
            Issue.record("expected .ok, got \(state)")
            return
        }
        #expect(snapshot.limits.first?.percent == 37)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    }

    @Test func tokenWithoutExpiryStillFetches() async {
        let transport = FakeTransport(reply(200, body: validBody))
        let state = await service(.success(creds(expiresIn: nil)), transport: transport).load()
        guard case .ok = state else {
            Issue.record("expected .ok, got \(state)")
            return
        }
    }

    @Test func serverFailureIsFailed() async {
        let transport = FakeTransport(reply(500))
        let state = await service(.success(creds(expiresIn: 3600)), transport: transport).load()
        #expect(state == .failed(.http(status: 500)))
    }

    @Test func rateLimitIsFailed() async {
        let transport = FakeTransport(reply(429, headers: ["Retry-After": "30"]))
        let state = await service(.success(creds(expiresIn: 3600)), transport: transport).load()
        #expect(state == .failed(.rateLimited(retryAfter: 30)))
    }
}
