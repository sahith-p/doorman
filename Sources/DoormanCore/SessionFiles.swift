import Foundation

/// Signs in inside a throwaway hidden browser, then saves the session as a Playwright storage state file.
/// No agent is attached while it happens, so a password never sits in a page an agent could read. The
/// file is still a live login, so it's owner-only, short-lived, and deleted when it expires.
public final class HiddenSessionRunner: SessionFileRunner, @unchecked Sendable {
    private let hub: ConnectionHub
    private let hostBinary: String
    private let fillExtensionPath: String
    private let directory: URL
    private let environment: [String: String]
    private let lifetime: TimeInterval
    private let current = LockedValue<HiddenChrome?>(nil)
    private let extensionCopy = LockedValue<URL?>(nil)

    public init(hub: ConnectionHub, hostBinary: String, fillExtensionPath: String, directory: URL, environment: [String: String] = [:], lifetime: TimeInterval = 15 * 60) {
        self.hub = hub
        self.hostBinary = hostBinary
        self.fillExtensionPath = fillExtensionPath
        self.directory = directory
        self.environment = environment
        self.lifetime = lifetime
    }

    /// A copy of the extension with the cookie permission added. Only this throwaway browser ever has
    /// that permission: the extension in your own Chrome doesn't, so nothing can ask it for your cookies.
    private func sessionExtension() throws -> URL {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("doorman-session-ext-\(UUID().uuidString)")
        try fm.copyItem(at: URL(fileURLWithPath: fillExtensionPath), to: copy)
        let manifestURL = copy.appendingPathComponent("manifest.json")
        guard var manifest = (try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))) as? [String: Any] else {
            throw HiddenChromeError.failed("bad extension manifest")
        }
        manifest["permissions"] = (manifest["permissions"] as? [String] ?? []) + ["cookies"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        return copy
    }

    public func begin(address: URL) async throws -> (adapter: BrowserAdapter, tab: String) {
        guard let binary = HiddenChrome.findBrowser() else { throw HiddenChromeError.noBrowser }
        guard current.value == nil else { throw HiddenChromeError.failed("another session file is being made") }
        let ext = try sessionExtension()
        extensionCopy.value = ext
        let chrome = HiddenChrome(
            binary: binary,
            profile: FileManager.default.temporaryDirectory.appendingPathComponent("doorman-session-\(UUID().uuidString)"),
            extensions: [ext.path],
            nativeHosts: [.init(name: DoormanConstants.nativeHostName, manifest: nativeHostManifest(path: hostBinary, allowedExtensionIDs: [DoormanConstants.fillExtensionID]))],
            environment: environment)
        try await chrome.start()
        current.value = chrome
        hub.markHidden(browserPID: chrome.processID)
        for _ in 0..<100 {
            if let adapter = hub.adapter(browserPID: chrome.processID) {
                let tab = try await adapter.open(url: address)
                return (adapter, tab)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await abort()
        throw HiddenChromeError.failed("hidden browser's extension didn't connect")
    }

    public func finish(adapter: BrowserAdapter, tab: String, host: String, label: String) async throws -> (path: String, expires: Date) {
        defer { stopChrome() }
        guard let adapter = adapter as? ExtensionAdapter else { throw HiddenChromeError.failed("wrong adapter") }
        let state = try await adapter.exportSession(tab: tab, expectedHost: host)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let file = directory.appendingPathComponent("\(String(safe))-\(UUID().uuidString.prefix(8)).json")
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: file)
        let expires = Date().addingTimeInterval(lifetime)
        return (file.path, expires)
    }

    public func abort() async { stopChrome() }

    private func stopChrome() {
        guard let chrome = current.value else { return }
        current.value = nil
        hub.unmarkHidden(browserPID: chrome.processID)
        chrome.stop()
        if let ext = extensionCopy.value { try? FileManager.default.removeItem(at: ext) }
        extensionCopy.value = nil
    }

    /// Deletes expired files. Run on a timer rather than per file, so it also covers files left by a
    /// previous run or a crash.
    public func sweep() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > lifetime { try? FileManager.default.removeItem(at: file) }
        }
    }
}
