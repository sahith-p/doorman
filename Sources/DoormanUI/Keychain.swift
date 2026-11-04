import Foundation
import Security
import CryptoKit
import DoormanCore

/// Doorman's own Keychain items. macOS only hands these to Doorman without asking, so another program,
/// including an agent's shell, triggers a macOS prompt you'd see.
public enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: DoormanConstants.keychainService,
         kSecAttrAccount as String: account]
    }

    public static func set(_ data: Data, account: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    public static func get(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public static func has(account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

public enum KeychainError: Error { case status(OSStatus) }

public final class KeychainSigningKey: SigningKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: SymmetricKey?
    public init() {}

    public func signingKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let data = Keychain.get(account: "settings-signing-key") {
            let key = SymmetricKey(data: data)
            cached = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try Keychain.set(key.withUnsafeBytes { Data($0) }, account: "settings-signing-key")
        cached = key
        return key
    }
}

public struct KeychainGenerationStore: GenerationStore {
    public init() {}
    public func current() -> Int {
        Keychain.get(account: "settings-generation").flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    }
    public func set(_ value: Int) { try? Keychain.set(Data(String(value).utf8), account: "settings-generation") }
}

public struct KeychainAppleSessionStore: AppleSessionStore {
    public init() {}
    public func load() -> AppleSession? {
        Keychain.get(account: "apple-session").flatMap { try? JSONDecoder().decode(AppleSession.self, from: $0) }
    }
    public func save(_ session: AppleSession?) {
        if let session, let data = try? JSONEncoder().encode(session) {
            try? Keychain.set(data, account: "apple-session")
        } else {
            Keychain.delete(account: "apple-session")
        }
    }
}

public struct KeychainGmailStore: GmailTokenStore {
    public init() {}
    public func load() -> GmailTokens? {
        guard let data = Keychain.get(account: "gmail-tokens") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GmailTokens.self, from: data)
    }
    public func save(_ tokens: GmailTokens?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let tokens, let data = try? encoder.encode(tokens) {
            try? Keychain.set(data, account: "gmail-tokens")
        } else {
            Keychain.delete(account: "gmail-tokens")
        }
    }
}

/// Where each account's password comes from.
public struct AppPasswordSource: PasswordSource {
    let apple: AppleConnection

    private static func vaultAccount(_ id: UUID) -> String { "vault-\(id.uuidString)" }

    public static func storePassword(_ secret: Secret, accountID: UUID) throws {
        try Keychain.set(Data(secret.reveal().utf8), account: vaultAccount(accountID))
    }
    public static func hasStoredPassword(accountID: UUID) -> Bool { Keychain.has(account: vaultAccount(accountID)) }
    public static func deleteStoredPassword(accountID: UUID) { Keychain.delete(account: vaultAccount(accountID)) }

    public func credential(for account: Account, host: String) async throws -> Credential {
        switch account.credential {
        case .none:
            throw PasswordSourceError.notFound
        case .stored:
            guard let data = Keychain.get(account: Self.vaultAccount(account.id)) else { throw PasswordSourceError.notFound }
            return Credential(username: account.login, password: Secret(String(decoding: data, as: UTF8.self)))
        case let .applePasswords(site):
            try await ensureConnected()
            do {
                guard let credential = try await apple.client.credential(site: normalizeHost(site), username: account.login) else {
                    throw PasswordSourceError.notFound
                }
                return credential
            } catch AppleProtocolError.notPaired {
                throw PasswordSourceError.notConnected
            }
        }
    }

    public func authenticatorCode(for account: Account, url: URL) async throws -> Secret? {
        try await ensureConnected()
        do {
            return try await apple.client.authenticatorCode(url: url.absoluteString, username: account.login)
        } catch AppleProtocolError.notPaired {
            throw PasswordSourceError.notConnected
        }
    }

    private func ensureConnected() async throws {
        let state = try? await apple.connect()
        guard state == .paired else { throw PasswordSourceError.notConnected }
    }
}
