import Foundation
import Testing
@testable import AgentsBarCore

private func parse(_ json: String) throws -> ClaudeCredentials {
    try CredentialsParser.parse(Data(json.utf8))
}

private struct FakeStore: SecretStore {
    let result: Result<Data?, CredentialsError>

    func genericPassword(service: String) throws -> Data? {
        #expect(service == "Claude Code-credentials")
        return try result.get()
    }
}

@Suite struct CredentialsParserTests {
    @Test func validPayloadConvertsMillisecondsToDate() throws {
        let creds = try parse("""
        {"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"ref-456",
         "expiresAt":1767225600000,"scopes":["user:inference"],"subscriptionType":"max"}}
        """)
        #expect(creds == ClaudeCredentials(
            accessToken: "tok-123",
            expiresAt: Date(timeIntervalSince1970: 1_767_225_600),
            subscriptionType: "max"
        ))
    }

    @Test func missingExpiresAtAndSubscriptionAreTolerated() throws {
        let creds = try parse(#"{"claudeAiOauth":{"accessToken":"tok"}}"#)
        #expect(creds == ClaudeCredentials(accessToken: "tok", expiresAt: nil, subscriptionType: nil))
    }

    @Test func missingAccessTokenThrows() {
        #expect(throws: CredentialsError.missingAccessToken) {
            try parse(#"{"claudeAiOauth":{"expiresAt":1}}"#)
        }
    }

    @Test func emptyAccessTokenThrows() {
        #expect(throws: CredentialsError.missingAccessToken) {
            try parse(#"{"claudeAiOauth":{"accessToken":""}}"#)
        }
    }

    @Test func invalidJSONThrows() {
        #expect(throws: CredentialsError.invalidPayload) { try parse("not json") }
    }

    @Test func nonObjectClaudeAiOauthThrows() {
        #expect(throws: CredentialsError.invalidPayload) { try parse(#"{"claudeAiOauth":"nope"}"#) }
        #expect(throws: CredentialsError.invalidPayload) { try parse(#"{"other":{}}"#) }
    }
}

@Suite struct ClaudeCredentialsExpiryTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func expiredWhenExpiresAtIsNowOrEarlier() {
        let at = ClaudeCredentials(accessToken: "t", expiresAt: now, subscriptionType: nil)
        let before = ClaudeCredentials(accessToken: "t", expiresAt: now.addingTimeInterval(-1), subscriptionType: nil)
        #expect(at.isExpired(now: now))
        #expect(before.isExpired(now: now))
    }

    @Test func notExpiredWhenInFutureOrUnknown() {
        let future = ClaudeCredentials(accessToken: "t", expiresAt: now.addingTimeInterval(1), subscriptionType: nil)
        let unknown = ClaudeCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil)
        #expect(!future.isExpired(now: now))
        #expect(!unknown.isExpired(now: now))
    }
}

@Suite struct CredentialsProviderTests {
    @Test func noItemMeansNotSignedIn() throws {
        let provider = CredentialsProvider(store: FakeStore(result: .success(nil)))
        #expect(try provider.load() == nil)
    }

    @Test func itemIsParsed() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8)
        let provider = CredentialsProvider(store: FakeStore(result: .success(data)))
        #expect(try provider.load()?.accessToken == "tok")
    }

    @Test func storeErrorPropagates() {
        let provider = CredentialsProvider(store: FakeStore(result: .failure(.keychain(-25308))))
        #expect(throws: CredentialsError.keychain(-25308)) { try provider.load() }
    }

    @Test func malformedItemPropagatesParseError() {
        let provider = CredentialsProvider(store: FakeStore(result: .success(Data("x".utf8))))
        #expect(throws: CredentialsError.invalidPayload) { try provider.load() }
    }
}
