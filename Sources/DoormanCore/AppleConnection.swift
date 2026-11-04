import Foundation

public enum AppleConnectionError: Error, Equatable {
    case helperMissing
    case noBrowser
    case relayDidNotConnect
}

/// Runs the hidden Chrome that Apple's helper needs. Apple's helper refuses anything but a browser, so
/// this starts one with a private profile and only the relay extension in it. Once it's up, `client`
/// talks to the helper through it.
public final class AppleConnection: @unchecked Sendable {
    public static let appleManifest = "/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json"

    public let client: AppleClient
    private let hub: ConnectionHub
    private let hostBinary: String
    private let relayExtensionPath: String
    private let profile: URL
    private let environment: [String: String]
    private let chrome = LockedValue<HiddenChrome?>(nil)
    private let starting = AsyncSerial()

    public init(hub: ConnectionHub, hostBinary: String, relayExtensionPath: String, store: AppleSessionStore, profile: URL? = nil, environment: [String: String] = [:]) {
        self.hub = hub
        self.hostBinary = hostBinary
        self.relayExtensionPath = relayExtensionPath
        self.profile = profile ?? FileManager.default.temporaryDirectory.appendingPathComponent("doorman-apple-\(getpid())")
        self.environment = environment
        self.client = AppleClient(transport: RelayTransport(hub: hub), store: store)
        hub.appleClient = client
    }

    public var isRunning: Bool { chrome.value?.isRunning ?? false }

    /// Starts hidden Chrome if needed and says hello. Safe to call again. Never shows a PIN.
    @discardableResult
    public func connect() async throws -> AppleConnectionState {
        try await starting.run { [self] in
            if !hub.relayConnected || !(chrome.value?.isRunning ?? false) {
                try await startChrome()
            }
            return try await client.hello()
        }
    }

    private func startChrome() async throws {
        chrome.value?.stop()
        guard let binary = HiddenChrome.findBrowser() else { throw AppleConnectionError.noBrowser }
        guard let manifestData = FileManager.default.contents(atPath: Self.appleManifest),
              let appleManifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any] else {
            throw AppleConnectionError.helperMissing
        }
        let hosts: [HiddenChrome.NativeHost] = [
            .init(name: "com.apple.passwordmanager", manifest: appleManifest),
            .init(name: DoormanConstants.nativeHostName, manifest: nativeHostManifest(path: hostBinary, allowedExtensionIDs: [DoormanConstants.appleExtensionID])),
        ]
        let hidden = HiddenChrome(binary: binary, profile: profile, extensions: [relayExtensionPath], nativeHosts: hosts, environment: environment)
        try await hidden.start()
        chrome.value = hidden
        for _ in 0..<150 {
            if hub.relayConnected { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        hidden.stop()
        chrome.value = nil
        throw AppleConnectionError.relayDidNotConnect
    }

    public func disconnect() {
        chrome.value?.stop()
        chrome.value = nil
    }
}

/// Runs one async job at a time, so two sign-ins can't start two hidden browsers.
actor AsyncSerial {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ job: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await job()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
