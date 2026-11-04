import Foundation
import CryptoKit

/// The key the settings are signed with. In the app it's a Keychain item.
public protocol SigningKeyProvider: Sendable {
    func signingKey() throws -> SymmetricKey
}

public struct InMemorySigningKey: SigningKeyProvider {
    private let key: SymmetricKey
    public init(_ key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    public func signingKey() throws -> SymmetricKey { key }
}

/// How many times settings have been saved, kept outside the settings folder, so an old file and its
/// valid signature can't be put back to undo a later change.
public protocol GenerationStore: Sendable {
    func current() -> Int
    func set(_ value: Int)
}

public final class InMemoryGenerationStore: GenerationStore, @unchecked Sendable {
    private let box = LockedValue(0)
    public init() {}
    public func current() -> Int { box.value }
    public func set(_ value: Int) { box.value = value }
}

public enum SettingsLoad: Equatable, Sendable {
    case empty
    case ok(DoormanSettings)
    /// The file doesn't match its signature: something other than Doorman changed it. It isn't used
    /// until you look at it and approve it with Touch ID.
    case changedOutside(DoormanSettings?)
}

/// `settings.json` plus an HMAC in `settings.sig`. An agent running as you can edit either file, but
/// can't produce a valid signature without the Keychain key.
public final class SettingsStore: @unchecked Sendable {
    public let directory: URL
    private let keys: SigningKeyProvider
    private let generations: GenerationStore
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }
    private var sigURL: URL { directory.appendingPathComponent("settings.sig") }

    public init(directory: URL, keys: SigningKeyProvider, generations: GenerationStore = InMemoryGenerationStore()) {
        self.directory = directory
        self.keys = keys
        self.generations = generations
    }

    public func load() throws -> SettingsLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // A signature with no file means the settings were deleted from outside.
            return FileManager.default.fileExists(atPath: sigURL.path) ? .changedOutside(nil) : .empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try? JSONDecoder().decode(DoormanSettings.self, from: data)
        guard let sig = try? Data(contentsOf: sigURL),
              HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: data, using: try keys.signingKey()) else {
            return .changedOutside(decoded)
        }
        guard let settings = decoded else { return .changedOutside(nil) }
        // Validly signed, but older than the last save: someone put an old copy back.
        guard settings.generation >= generations.current() else { return .changedOutside(settings) }
        return .ok(settings)
    }

    /// Callers get the tap first. See `SettingsController` in the app.
    public func save(_ settings: DoormanSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var stamped = settings
        stamped.generation = generations.current() + 1
        let data = try encoder.encode(stamped)
        let sig = Data(HMAC<SHA256>.authenticationCode(for: data, using: try keys.signingKey()))
        try data.write(to: fileURL, options: .atomic)
        try sig.write(to: sigURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sigURL.path)
        generations.set(stamped.generation)
    }
}
