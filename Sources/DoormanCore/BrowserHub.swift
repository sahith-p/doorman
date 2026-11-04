import Foundation

/// A connected Chrome extension. Each profile that has the extension is one of these.
public final class ExtensionAdapter: BrowserAdapter, @unchecked Sendable {
    public let name: String
    private let channel: LineChannel
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Any, Error>] = [:]
    /// The browser process this adapter lives in.
    public let browserPID: pid_t

    public init(name: String, channel: LineChannel, browserPID: pid_t = -1) {
        self.name = name
        self.channel = channel
        self.browserPID = browserPID
    }

    func deliver(_ object: [String: Any]) {
        guard let id = object["id"] as? Int else { return }
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if object["ok"] as? Bool == true {
            continuation.resume(returning: object["result"] ?? NSNull())
        } else {
            continuation.resume(throwing: BrowserError.failed(object["error"] as? String ?? "failed"))
        }
    }

    func disconnected() {
        lock.lock()
        let all = waiting
        waiting = [:]
        lock.unlock()
        for (_, c) in all { c.resume(throwing: BrowserError.disconnected) }
    }

    private func call(_ cmd: String, _ fields: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> Any {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        var message = fields
        message["id"] = id
        message["cmd"] = cmd
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting[id] = continuation }
            guard channel.send(json: message) else {
                let c = lock.withLock { waiting.removeValue(forKey: id) }
                c?.resume(throwing: BrowserError.disconnected)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                let c = lock.withLock { waiting.removeValue(forKey: id) }
                c?.resume(throwing: BrowserError.failed("timed out"))
            }
        }
    }

    func rawCall(_ cmd: String, _ fields: [String: Any]) async throws -> Any { try await call(cmd, fields) }

    public func tabs() async throws -> [TabInfo] {
        let result = try await call("tabs")
        return ((result as? [[String: Any]]) ?? []).compactMap { t in
            guard let id = t["id"] as? String, let url = t["url"] as? String else { return nil }
            return TabInfo(id: id, url: url, title: t["title"] as? String ?? "", active: t["active"] as? Bool ?? false)
        }
    }

    public func open(url: URL) async throws -> String {
        let result = try await call("open", ["url": url.absoluteString]) as? [String: Any]
        guard let id = result?["id"] as? String else { throw BrowserError.failed("no tab") }
        return id
    }

    public func inspect(tab: String) async throws -> PageState {
        let result = try await call("inspect", ["tab": tab]) as? [String: Any] ?? [:]
        guard let url = result["url"] as? String else { throw BrowserError.failed("no page") }
        return PageState(url: url, username: result["username"] as? Bool ?? false, password: result["password"] as? Bool ?? false,
                         code: result["code"] as? Bool ?? false, captcha: result["captcha"] as? Bool ?? false,
                         loginHints: result["loginHints"] as? Bool ?? false, frameLogin: result["frameLogin"] as? Bool ?? false)
    }

    public func fillLogin(tab: String, expectedHost: String, username: String?, password: Secret?, submit: Bool) async throws {
        var fields: [String: Any] = ["tab": tab, "submit": submit, "expectedHost": expectedHost]
        if let username { fields["username"] = username }
        if let password { fields["password"] = password.reveal() }
        _ = try await call("fillLogin", fields)
    }

    public func fillCode(tab: String, expectedHost: String, code: Secret, submit: Bool) async throws {
        _ = try await call("fillCode", ["tab": tab, "code": code.reveal(), "submit": submit, "expectedHost": expectedHost])
    }

    public func navigate(tab: String, url: URL) async throws {
        _ = try await call("navigate", ["tab": tab, "url": url.absoluteString])
    }

    /// Playwright storage state, as a JSON object.
    public func exportSession(tab: String, expectedHost: String) async throws -> Any {
        try await call("exportSession", ["tab": tab, "expectedHost": expectedHost])
    }
}

/// Everything connected over the socket: browsers on one side, agents on the other.
public final class ConnectionHub: @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [ObjectIdentifier: ExtensionAdapter] = [:]
    private var relay: LineChannel?
    private var hiddenBrowserPIDs: Set<pid_t> = []
    public var appleClient: AppleClient?
    /// Called when the hidden browser's relay connects.
    public var onRelayConnected: (@Sendable () -> Void)?
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Browsers a normal sign-in can use. Doorman's own hidden browsers aren't where an agent is working.
    public var adapters: [BrowserAdapter] {
        lock.lock()
        defer { lock.unlock() }
        return browsers.values.filter { !hiddenBrowserPIDs.contains($0.browserPID) }
    }

    public func markHidden(browserPID: pid_t) {
        lock.lock()
        hiddenBrowserPIDs.insert(browserPID)
        lock.unlock()
    }

    public func unmarkHidden(browserPID: pid_t) {
        lock.lock()
        hiddenBrowserPIDs.remove(browserPID)
        lock.unlock()
    }

    /// The extension connected from a particular browser process, including hidden ones.
    public func adapter(browserPID: pid_t) -> ExtensionAdapter? {
        lock.lock()
        defer { lock.unlock() }
        return browsers.values.first { $0.browserPID == browserPID }
    }

    public var browserCount: Int { adapters.count }

    func addBrowser(_ adapter: ExtensionAdapter, key: ObjectIdentifier) {
        lock.withLock { browsers[key] = adapter }
        onChange?()
    }

    func removeBrowser(key: ObjectIdentifier) {
        lock.lock()
        let adapter = browsers.removeValue(forKey: key)
        lock.unlock()
        adapter?.disconnected()
        onChange?()
    }

    func setRelay(_ channel: LineChannel?) {
        lock.lock()
        relay = channel
        lock.unlock()
    }

    public func sendToRelay(_ data: Data) throws {
        lock.lock()
        let channel = relay
        lock.unlock()
        guard let channel, channel.send(data) else { throw AppleProtocolError.disconnected }
    }

    public var relayConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return relay != nil
    }
}

/// Sends Apple's helper its messages through the hidden browser's relay.
public struct RelayTransport: AppleTransport {
    let hub: ConnectionHub
    public init(hub: ConnectionHub) { self.hub = hub }
    public func send(_ json: Data) async throws { try hub.sendToRelay(json) }
}

extension ExtensionAdapter {
    /// Test helper: closes every tab on a host but keeps the browser open.
    public func closeDemoTabs(host: String) async throws {
        _ = try await rawCall("closeTabs", ["host": host])
    }
}
