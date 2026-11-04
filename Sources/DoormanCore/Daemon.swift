import Foundation

/// The agent's side of Doorman. Requests come in over the socket and run on the engine, and the only
/// thing that goes back is a `SignInResult`, which has no field that can hold a secret.
public final class Daemon: @unchecked Sendable {
    public let hub: ConnectionHub
    private let engine: SignInEngine
    private let settings: @Sendable () -> SettingsSnapshot
    private let server: UnixSocketServer
    /// Where a real native host binary lives. Only that binary, started by a signed browser, can be a browser.
    private let expectedHostPath: String
    /// Recorded at start, so swapping the file while Doorman runs doesn't get a new program in.
    private let expectedHostHash: Data?
    private let statusProvider: @Sendable () -> [String: Any]
    private let lock = NSLock()
    private var requests: [String: RequestState] = [:]

    private final class RequestState: @unchecked Sendable {
        let lock = NSLock()
        var result: SignInResult?
        var waiters: [CheckedContinuation<Void, Never>] = []
        func finish(_ r: SignInResult) {
            let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                result = r
                let w = waiters
                waiters = []
                return w
            }
            for c in w { c.resume() }
        }
    }

    public init(socketPath: String, hub: ConnectionHub, engine: SignInEngine, settings: @escaping @Sendable () -> SettingsSnapshot,
                expectedHostPath: String, statusProvider: @escaping @Sendable () -> [String: Any] = { [:] }) {
        self.hub = hub
        self.engine = engine
        self.settings = settings
        self.server = UnixSocketServer(path: socketPath)
        self.expectedHostPath = expectedHostPath
        self.expectedHostHash = PeerCheck.codeHash(path: expectedHostPath)
        self.statusProvider = statusProvider
    }

    public func start() throws {
        try server.start { [weak self] channel in self?.accept(channel) }
    }

    public func stop() { server.stop() }

    private func accept(_ channel: LineChannel) {
        let first = FirstLine()
        channel.onLine = { [weak self] line in
            guard let self else { return }
            if let handler = first.handler {
                handler(line)
                return
            }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                channel.close()
                return
            }
            first.handler = self.route(hello: object, channel: channel)
            if first.handler == nil { channel.close() }
        }
        channel.start()
    }

    private final class FirstLine: @unchecked Sendable { var handler: (@Sendable (Data) -> Void)? }

    /// The first line says who the connection claims to be. Agent is available to anyone: it can't get a
    /// secret. Browser and relay can, so those are checked against the kernel's view of the peer.
    private func route(hello: [String: Any], channel: LineChannel) -> (@Sendable (Data) -> Void)? {
        if hello["hello"] as? String == "agent" {
            return { [weak self] line in self?.handleAgent(line, channel: channel) }
        }
        guard let host = hello["hostHello"] as? [String: Any], let origin = host["origin"] as? String else { return nil }
        guard let browserPID = PeerCheck.browserOwningHost(channel: channel, expectedHash: expectedHostHash) else {
            NSLog("Doorman: refused a browser connection from %@", PeerCheck.executablePath(pid: channel.peerPID) ?? "unknown")
            return nil
        }
        if origin == "chrome-extension://\(DoormanConstants.fillExtensionID)/" {
            return attachBrowser(channel, browserPID: browserPID)
        }
        if origin == "chrome-extension://\(DoormanConstants.appleExtensionID)/" {
            return attachRelay(channel)
        }
        return nil
    }

    private func attachBrowser(_ channel: LineChannel, browserPID: pid_t) -> @Sendable (Data) -> Void {
        let adapter = ExtensionAdapter(name: PeerCheck.browserName(pid: browserPID), channel: channel, browserPID: browserPID)
        let key = ObjectIdentifier(channel)
        hub.addBrowser(adapter, key: key)
        channel.onClose = { [hub] in hub.removeBrowser(key: key) }
        return { line in
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            adapter.deliver(object)
        }
    }

    private func attachRelay(_ channel: LineChannel) -> @Sendable (Data) -> Void {
        hub.setRelay(channel)
        let hub = self.hub
        channel.onClose = { [hub] in
            hub.setRelay(nil)
            if let apple = hub.appleClient { Task { await apple.transportClosed() } }
        }
        hub.onRelayConnected?()
        return { line in
            guard let apple = hub.appleClient else { return }
            // The relay's own note that the helper went away, as opposed to a message from the helper.
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["relay"] != nil {
                Task { await apple.transportClosed() }
                return
            }
            Task { await apple.deliver(line) }
        }
    }

    // MARK: Agent API

    private func handleAgent(_ line: Data, channel: LineChannel) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] else { return }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        Task {
            let reply: [String: Any]
            switch method {
            case "sign_in":
                reply = encode(await self.startSignIn(params))
            case "check_sign_in":
                reply = encode(await self.check(params))
            case "options":
                reply = self.options()
            case "status":
                reply = self.status()
            default:
                reply = ["error": "unknown method"]
            }
            channel.send(json: ["id": id, "result": reply])
        }
    }

    private func encode(_ result: SignInResult) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["status": "failed"]
        }
        return object
    }

    private func startSignIn(_ params: [String: Any]) async -> SignInResult {
        guard let url = params["url"] as? String else {
            return SignInResult(status: .failed, reason: Reason.invalidAddress, message: "sign_in needs a url.")
        }
        let request = SignInRequest(address: url, role: params["role"] as? String, account: params["account"] as? String,
                                    reason: params["reason"] as? String ?? "", agent: params["agent"] as? String ?? "agent",
                                    sessionFile: params["session_file"] as? Bool ?? false, browser: params["browser"] as? String)
        let requestID = UUID().uuidString
        let state = RequestState()
        lock.withLock { requests[requestID] = state }
        let engine = self.engine
        Task {
            let result = await engine.signIn(request)
            state.finish(result)
            // Keep the answer long enough for an agent to come back for it.
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            self.forget(requestID)
        }
        return await wait(requestID: requestID, state: state, seconds: Self.waitSeconds(params))
    }

    /// The number comes from the agent, and a huge one must not crash the app.
    static func waitSeconds(_ params: [String: Any]) -> Double {
        let asked = (params["wait_seconds"] as? NSNumber)?.doubleValue ?? 50
        guard asked.isFinite else { return 50 }
        return min(max(asked, 0), 300)
    }

    private func forget(_ id: String) {
        _ = lock.withLock { requests.removeValue(forKey: id) }
    }

    private func check(_ params: [String: Any]) async -> SignInResult {
        guard let id = params["request_id"] as? String else {
            return SignInResult(status: .failed, reason: Reason.invalidAddress, message: "check_sign_in needs a request_id.")
        }
        let state = lock.withLock { requests[id] }
        guard let state else { return SignInResult(status: .failed, reason: "unknown_request", message: "Doorman has no such request. It may have expired.") }
        return await wait(requestID: id, state: state, seconds: Self.waitSeconds(params))
    }

    /// Waits, but not forever: some MCP clients give up on a tool after about a minute. So past the
    /// wait, the agent gets `pending` and a request ID and can call `check_sign_in`.
    private func wait(requestID: String, state: RequestState, seconds: Double) async -> SignInResult {
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let finished = state.lock.withLock { () -> Bool in
                        if state.result != nil { return true }
                        state.waiters.append(c)
                        return false
                    }
                    if finished { c.resume() }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            if !first {
                // Release the waiter so the group can finish. The request itself keeps running.
                let w = state.lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    let w = state.waiters
                    state.waiters = []
                    return w
                }
                for c in w { c.resume() }
            }
            group.cancelAll()
            return first
        }
        let result = state.lock.withLock { state.result }
        if finished || result != nil, let result {
            var out = result
            out.requestID = requestID
            return out
        }
        return SignInResult(status: .pending, reason: "waiting_for_you", message: "Waiting for approval or for the site. Call check_sign_in with this request_id.", requestID: requestID)
    }

    /// Names only, so an agent can pick a role or account. No login names, and no secrets.
    private func options() -> [String: Any] {
        guard case let .usable(current) = settings() else { return ["apps": []] }
        return ["apps": current.apps.map { app -> [String: Any] in
            ["name": app.name,
             "host": normalizeHost(app.host),
             "test": app.isTest,
             "roles": app.roles.map { ["name": $0.name, "path": normalizePath($0.path)] },
             "accounts": app.accounts.compactMap { account -> [String: Any]? in
                 guard let role = app.roles.first(where: { $0.id == account.roleID }) else { return nil }
                 return ["name": account.name, "role": role.name, "asks_first": Approval.asksFirst(account: account)]
             }] as [String: Any]
        }]
    }

    private func status() -> [String: Any] {
        var out = statusProvider()
        out["browsers"] = hub.browserCount
        if case let .usable(current) = settings() { out["paused"] = current.paused }
        return out
    }
}
