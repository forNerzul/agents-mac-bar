import Foundation

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public enum CredentialsError: Error, Equatable {
    case invalidPayload
    case missingAccessToken
    case securityTool(exitCode: Int32)
    case securityToolUnavailable
    case securityToolTimedOut
}

public enum CredentialsParser {
    /// Only the access token, expiry and plan are read; the refresh token is deliberately ignored.
    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            throw CredentialsError.invalidPayload
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialsError.missingAccessToken
        }
        // `expiresAt` is epoch milliseconds.
        var expiresAt: Date?
        if let millis = oauth["expiresAt"] as? NSNumber, CFGetTypeID(millis) != CFBooleanGetTypeID() {
            expiresAt = Date(timeIntervalSince1970: millis.doubleValue / 1000)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}

public protocol SecretStore: Sendable {
    func genericPassword(service: String) throws -> Data?
}

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data

    public init(exitCode: Int32, stdout: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> ProcessResult
}

private final class OutputBox: @unchecked Sendable {
    // Written once by the reader queue; read only after the group has been waited on.
    var data = Data()
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr is never surfaced.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw CredentialsError.securityToolUnavailable
        }
        // The parent must not hold the write end, or the reader would never see EOF.
        try? pipe.fileHandleForWriting.close()

        // Drain stdout concurrently: the payload can exceed the pipe buffer and would block the child.
        let output = OutputBox()
        let reader = DispatchGroup()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global().async(group: reader) {
            output.data = handle.readDataToEndOfFile()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw CredentialsError.securityToolTimedOut
        }
        reader.wait()
        return ProcessResult(exitCode: process.terminationStatus, stdout: output.data)
    }
}

/// Reads through `/usr/bin/security`, the tool the item already trusts and Claude Code itself uses,
/// so macOS does not show a Keychain prompt.
public struct SecurityToolSecretStore: SecretStore {
    private static let itemNotFoundExitCode: Int32 = 44

    private let runner: ProcessRunning
    private let executable: URL
    private let timeout: TimeInterval

    public init(
        runner: ProcessRunning = FoundationProcessRunner(),
        executable: URL = URL(fileURLWithPath: "/usr/bin/security"),
        timeout: TimeInterval = 5
    ) {
        self.runner = runner
        self.executable = executable
        self.timeout = timeout
    }

    public func genericPassword(service: String) throws -> Data? {
        let result = try runner.run(
            executable: executable,
            arguments: ["find-generic-password", "-s", service, "-w"],
            timeout: timeout
        )
        switch result.exitCode {
        case 0:
            // The tool appends a single "\n" after the secret.
            var data = result.stdout
            if data.last == UInt8(ascii: "\n") { data.removeLast() }
            return data
        case Self.itemNotFoundExitCode:
            return nil
        default:
            throw CredentialsError.securityTool(exitCode: result.exitCode)
        }
    }
}

public protocol CredentialsLoading: Sendable {
    func load() throws -> ClaudeCredentials?
}

public struct CredentialsProvider: CredentialsLoading {
    private let store: SecretStore
    private let service: String

    public init(store: SecretStore = SecurityToolSecretStore(), service: String = "Claude Code-credentials") {
        self.store = store
        self.service = service
    }

    /// Returns nil when no item exists (the user is not signed in). Never refreshes or writes the token.
    public func load() throws -> ClaudeCredentials? {
        guard let data = try store.genericPassword(service: service) else { return nil }
        return try CredentialsParser.parse(data)
    }
}
