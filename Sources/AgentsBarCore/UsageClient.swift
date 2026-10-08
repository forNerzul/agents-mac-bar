import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Messages are safe to show in the UI; they never contain the access token.
public enum UsageClientError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case transport
    case parse(UsageParserError)
}

public struct UsageClient: Sendable {
    private let transport: HTTPTransport
    private let endpoint: URL

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    ) {
        self.transport = transport
        self.endpoint = endpoint
    }

    public func fetch(accessToken: String) async throws(UsageClientError) -> UsageSnapshot {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentsBar/\(AgentsBarCore.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw .transport
        }

        switch response.statusCode {
        case 200..<300:
            do {
                return try UsageParser.parse(data)
            } catch let error as UsageParserError {
                throw .parse(error)
            } catch {
                throw .parse(.invalidPayload)
            }
        case 401, 403:
            throw .unauthorized
        case 429:
            // Only the delta-seconds form is supported; HTTP-date values are ignored.
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            throw .rateLimited(retryAfter: retryAfter)
        default:
            throw .http(status: response.statusCode)
        }
    }
}

public enum LimitsState: Equatable, Sendable {
    case signedOut
    case credentialsUnavailable
    case expired
    case ok(UsageSnapshot)
    case failed(UsageClientError)
}

public struct LimitsService: Sendable {
    /// Tokens expiring within this margin are treated as expired to avoid racing the server clock.
    private static let expirySkew: TimeInterval = 60

    private let credentials: any CredentialsLoading
    private let client: UsageClient
    private let now: @Sendable () -> Date

    public init(
        credentials: some CredentialsLoading,
        client: UsageClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.client = client
        self.now = now
    }

    /// Never refreshes the token: Claude Code does that on its next run.
    public func load() async -> LimitsState {
        let loaded: ClaudeCredentials?
        do {
            loaded = try credentials.load()
        } catch {
            return .credentialsUnavailable
        }
        guard let loaded else { return .signedOut }
        if loaded.isExpired(now: now().addingTimeInterval(Self.expirySkew)) { return .expired }

        do {
            return .ok(try await client.fetch(accessToken: loaded.accessToken))
        } catch .unauthorized {
            return .expired
        } catch {
            return .failed(error)
        }
    }
}
