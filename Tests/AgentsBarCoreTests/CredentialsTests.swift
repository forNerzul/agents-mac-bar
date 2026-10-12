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

@Suite struct FileCredentialsProviderTests {
    private let url = URL(fileURLWithPath: "/tmp/fake/.credentials.json")

    @Test func missingFileMeansNotSignedIn() throws {
        let provider = FileCredentialsProvider(url: url, readFile: { _ in nil })
        #expect(try provider.load() == nil)
    }

    @Test func diskReaderReturnsNilForMissingFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(".credentials.json")
        #expect(try FileCredentialsProvider.readFromDisk(missing) == nil)
    }

    @Test func diskReaderReturnsFileContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try FileCredentialsProvider.readFromDisk(file) == Data("payload".utf8))
    }

    @Test func fileIsParsed() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":2000,"subscriptionType":"max"}}"#.utf8)
        let provider = FileCredentialsProvider(url: url, readFile: { requested in
            #expect(requested == url)
            return data
        })
        #expect(try provider.load() == ClaudeCredentials(
            accessToken: "tok",
            expiresAt: Date(timeIntervalSince1970: 2),
            subscriptionType: "max"
        ))
    }

    @Test func readErrorPropagates() {
        let provider = FileCredentialsProvider(url: url, readFile: { _ in throw CredentialsError.invalidPayload })
        #expect(throws: CredentialsError.invalidPayload) { try provider.load() }
    }

    @Test func malformedFilePropagatesParseError() {
        let provider = FileCredentialsProvider(url: url, readFile: { _ in Data("x".utf8) })
        #expect(throws: CredentialsError.invalidPayload) { try provider.load() }
    }

    @Test func defaultURLIsClaudeFallbackFile() {
        #expect(FileCredentialsProvider.defaultURL.path.hasSuffix("/.claude/.credentials.json"))
    }
}

private struct FakeSource: CredentialsLoading {
    let result: Result<ClaudeCredentials?, CredentialsError>

    func load() throws -> ClaudeCredentials? { try result.get() }
}

@Suite struct FreshestCredentialsProviderTests {
    private func creds(_ token: String, expires: TimeInterval?) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: token,
            expiresAt: expires.map { Date(timeIntervalSince1970: $0) },
            subscriptionType: nil
        )
    }

    private func provider(_ results: [Result<ClaudeCredentials?, CredentialsError>]) -> FreshestCredentialsProvider {
        FreshestCredentialsProvider(sources: results.map { FakeSource(result: $0) })
    }

    @Test func picksLaterExpiryRegardlessOfOrder() throws {
        let old = creds("old", expires: 100)
        let new = creds("new", expires: 200)
        #expect(try provider([.success(old), .success(new)]).load() == new)
        #expect(try provider([.success(new), .success(old)]).load() == new)
    }

    @Test func datedExpiryBeatsUnknown() throws {
        let dated = creds("dated", expires: 100)
        let undated = creds("undated", expires: nil)
        #expect(try provider([.success(undated), .success(dated)]).load() == dated)
        #expect(try provider([.success(dated), .success(undated)]).load() == dated)
    }

    @Test func tieKeepsEarlierSource() throws {
        let first = creds("first", expires: 100)
        let second = creds("second", expires: 100)
        #expect(try provider([.success(first), .success(second)]).load() == first)
        let undatedFirst = creds("a", expires: nil)
        let undatedSecond = creds("b", expires: nil)
        #expect(try provider([.success(undatedFirst), .success(undatedSecond)]).load() == undatedFirst)
    }

    @Test func failingSourceDoesNotHideSuccessfulOne() throws {
        let good = creds("good", expires: 100)
        #expect(try provider([.failure(.securityTool(exitCode: 1)), .success(good)]).load() == good)
        #expect(try provider([.success(good), .failure(.invalidPayload)]).load() == good)
    }

    @Test func allNilMeansNotSignedIn() throws {
        #expect(try provider([.success(nil), .success(nil)]).load() == nil)
        #expect(try provider([]).load() == nil)
    }

    @Test func noCredentialsAndAnErrorRethrowsFirstError() {
        let p = provider([.success(nil), .failure(.securityToolTimedOut), .failure(.invalidPayload)])
        #expect(throws: CredentialsError.securityToolTimedOut) { try p.load() }
    }
}
