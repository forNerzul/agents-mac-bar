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
        let provider = CredentialsProvider(store: FakeStore(result: .failure(.securityTool(exitCode: 1))))
        #expect(throws: CredentialsError.securityTool(exitCode: 1)) { try provider.load() }
    }

    @Test func malformedItemPropagatesParseError() {
        let provider = CredentialsProvider(store: FakeStore(result: .success(Data("x".utf8))))
        #expect(throws: CredentialsError.invalidPayload) { try provider.load() }
    }
}

private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    let result: Result<ProcessResult, CredentialsError>
    private(set) var calls: [(executable: URL, arguments: [String], timeout: TimeInterval)] = []

    init(_ result: Result<ProcessResult, CredentialsError>) { self.result = result }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        calls.append((executable, arguments, timeout))
        return try result.get()
    }
}

@Suite struct SecurityToolSecretStoreTests {
    private func store(_ runner: FakeRunner) -> SecurityToolSecretStore {
        SecurityToolSecretStore(runner: runner)
    }

    @Test func runsSecurityToolWithServiceOnly() throws {
        let runner = FakeRunner(.success(ProcessResult(exitCode: 0, stdout: Data("x\n".utf8))))
        _ = try store(runner).genericPassword(service: "Claude Code-credentials")
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == URL(fileURLWithPath: "/usr/bin/security"))
        #expect(runner.calls[0].arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        #expect(runner.calls[0].timeout == 5)
    }

    @Test func successStripsExactlyOneTrailingNewline() throws {
        let one = FakeRunner(.success(ProcessResult(exitCode: 0, stdout: Data("secret\n".utf8))))
        #expect(try store(one).genericPassword(service: "s") == Data("secret".utf8))
        let two = FakeRunner(.success(ProcessResult(exitCode: 0, stdout: Data("secret\n\n".utf8))))
        #expect(try store(two).genericPassword(service: "s") == Data("secret\n".utf8))
        let none = FakeRunner(.success(ProcessResult(exitCode: 0, stdout: Data("secret".utf8))))
        #expect(try store(none).genericPassword(service: "s") == Data("secret".utf8))
    }

    @Test func exit44MeansNoItem() throws {
        let runner = FakeRunner(.success(ProcessResult(exitCode: 44, stdout: Data())))
        #expect(try store(runner).genericPassword(service: "s") == nil)
    }

    @Test func otherExitCodeThrowsWithoutOutput() {
        let runner = FakeRunner(.success(ProcessResult(exitCode: 1, stdout: Data("leak".utf8))))
        #expect(throws: CredentialsError.securityTool(exitCode: 1)) {
            try store(runner).genericPassword(service: "s")
        }
    }

    @Test func runnerErrorsPropagate() {
        let runner = FakeRunner(.failure(.securityToolTimedOut))
        #expect(throws: CredentialsError.securityToolTimedOut) {
            try store(runner).genericPassword(service: "s")
        }
    }
}

@Suite struct FoundationProcessRunnerTests {
    private let runner = FoundationProcessRunner()

    @Test func capturesStdoutAndExitCode() throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 5)
        #expect(result == ProcessResult(exitCode: 0, stdout: Data("hello\n".utf8)))
    }

    @Test func reportsNonZeroExitCode() throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 44"], timeout: 5)
        #expect(result.exitCode == 44)
    }

    @Test func readsPayloadLargerThanPipeBuffer() throws {
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' a"],
            timeout: 10
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
    }

    @Test func readsLargePayloadWhileGlobalQueueIsSaturated() throws {
        // CI runners have few cores; parallel tests can exhaust the global dispatch pool.
        // The stdout reader must not depend on that pool being available.
        let release = DispatchSemaphore(value: 0)
        let blockers = 128
        for _ in 0..<blockers {
            DispatchQueue.global().async { release.wait() }
        }
        defer { for _ in 0..<blockers { release.signal() } }

        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' a"],
            timeout: 3
        )
        #expect(result.stdout.count == 200_000)
    }

    @Test func timeoutTerminatesProcessQuickly() {
        let start = Date()
        #expect(throws: CredentialsError.securityToolTimedOut) {
            try runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func missingExecutableIsUnavailable() {
        #expect(throws: CredentialsError.securityToolUnavailable) {
            try runner.run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 1)
        }
    }
}
