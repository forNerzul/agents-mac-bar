import Foundation
import Security

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
    case keychain(OSStatus)
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

public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func genericPassword(service: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw CredentialsError.keychain(status)
        }
    }
}

public struct CredentialsProvider {
    private let store: SecretStore
    private let service: String

    public init(store: SecretStore = KeychainSecretStore(), service: String = "Claude Code-credentials") {
        self.store = store
        self.service = service
    }

    /// Returns nil when no item exists (the user is not signed in). Never refreshes or writes the token.
    public func load() throws -> ClaudeCredentials? {
        guard let data = try store.genericPassword(service: service) else { return nil }
        return try CredentialsParser.parse(data)
    }
}
