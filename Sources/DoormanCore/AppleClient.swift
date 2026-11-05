import Foundation

/// Carries JSON both ways between Doorman and Apple's helper. In the app that's the hidden Chrome relay.
public protocol AppleTransport: Sendable {
    func send(_ json: Data) async throws
}

/// Keeps a finished pairing between launches. In the app it's a Keychain item.
public protocol AppleSessionStore: Sendable {
    func load() -> AppleSession?
    func save(_ session: AppleSession?)
}

public struct InMemoryAppleSessionStore: AppleSessionStore {
    private let box = LockedValue<AppleSession?>(nil)
    public init() {}
    public func load() -> AppleSession? { box.value }
    public func save(_ session: AppleSession?) { box.value = session }
}

public final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    public init(_ value: T) { stored = value }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

public enum AppleCommand {
    static let handshake = 2
    static let loginNames = 4
    static let password = 5
    static let passwordsDisabled = 9
    static let reloginNeeded = 10
    static let hello = 14
    static let listCodes = 16
    static let getCode = 17
    static let cancelPairing = 19
}

public enum AppleConnectionState: Equatable, Sendable {
    case notConnected
    case needsPairing
    case waitingForPIN
    case paired
    case disabled(String)
}

public struct ApplePasswordEntry: Sendable, Equatable {
    public var username: String
    public var sites: [String]
}

public struct AppleLookup: Sendable, Equatable {
    public var entries: [ApplePasswordEntry]
    public var requiresTouchID: Bool
}

/// Talks to Apple's helper over any transport. Only `credential` and `authenticatorCode` ever produce a
/// secret, and they return it as a `Secret`.
public actor AppleClient {
    private let transport: AppleTransport
    private let store: AppleSessionStore
    private let browserName: String
    private var pending: [(id: UUID, cmd: Int, continuation: CheckedContinuation<[String: Any], Error>)] = []
    private var busy = false
    private var queued: [CheckedContinuation<Void, Never>] = []
    private var useBase64 = false
    private var srp: SRPClient?
    private var serverHello: (salt: [UInt8], B: BigUInt)?
    private var session: AppleSession?
    /// `session` has been answered by the helper that's running now.
    private var sessionChecked = false
    private let sessionCheckTimeout: TimeInterval
    public private(set) var state: AppleConnectionState = .notConnected
    /// Non-secret facts from the helper's hello, for the Apple Passwords page.
    public private(set) var lastCapabilitiesSummary = ""

    public init(transport: AppleTransport, store: AppleSessionStore, browserName: String = "Doorman", sessionCheckTimeout: TimeInterval = 5) {
        self.sessionCheckTimeout = sessionCheckTimeout
        self.transport = transport
        self.store = store
        self.browserName = browserName
    }

    // MARK: Transport

    /// Every message from the helper arrives here. Replies are matched to the oldest request with the
    /// same command number, which is how Apple's own extension treats them.
    public func deliver(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let cmd = Self.int(message["cmd"]) else { return }
        if cmd == AppleCommand.passwordsDisabled || cmd == AppleCommand.reloginNeeded {
            session = nil
            sessionChecked = false
            store.save(nil)
            state = cmd == AppleCommand.passwordsDisabled
                ? .disabled("Passwords are off for browsers. Turn on AutoFill in the Passwords app settings.")
                : .needsPairing
            failAll(AppleProtocolError.notPaired)
            return
        }
        if let i = pending.firstIndex(where: { $0.cmd == cmd }) {
            let waiter = pending.remove(at: i)
            waiter.continuation.resume(returning: message)
        }
    }

    /// The relay's connection went away.
    public func transportClosed() {
        // The next helper is a new process, which won't know this session.
        sessionChecked = false
        state = .notConnected
        failAll(AppleProtocolError.disconnected)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending = []
        for w in waiting { w.continuation.resume(throwing: error) }
    }

    /// One question at a time. Replies only carry a command number, so two password lookups in flight
    /// could otherwise swap answers, and one site's password could be filled into another.
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { queued.append($0) }
    }

    private func releaseTurn() {
        if queued.isEmpty {
            busy = false
        } else {
            queued.removeFirst().resume()
        }
    }

    private func request(_ cmd: Int, _ object: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        await acquire()
        defer { releaseTurn() }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((id, cmd, continuation))
            Task {
                do {
                    try await transport.send(data)
                } catch {
                    self.cancelWaiter(id: id, error: AppleProtocolError.disconnected)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.cancelWaiter(id: id, error: AppleProtocolError.timedOut)
            }
        }
    }

    /// By this request's own ID, so an old timer can never cancel a newer request.
    private func cancelWaiter(id: UUID, error: Error) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let waiter = pending.remove(at: i)
        waiter.continuation.resume(throwing: error)
    }

    // MARK: Connecting

    /// Asks the helper what it supports, and picks up a saved pairing if this helper still knows it.
    /// Nothing here shows a PIN or reads a password.
    @discardableResult
    public func hello() async throws -> AppleConnectionState {
        let reply = try await request(AppleCommand.hello, ["cmd": AppleCommand.hello], timeout: 15)
        let capabilities = reply["capabilities"] as? [String: Any] ?? [:]
        useBase64 = capabilities["shouldUseBase64"] as? Bool ?? false
        // Facts about the helper only. There's nothing secret in a hello.
        lastCapabilitiesSummary = capabilities.keys.sorted().map { "\($0)=\(capabilities[$0] ?? "")" }.joined(separator: ", ")
        // A sign-in can say hello while you're typing the code. That mustn't take the code box away.
        if state == .waitingForPIN, srp != nil { return state }
        if sessionChecked, session?.useBase64 == useBase64 {
            state = .paired
            return state
        }
        guard let saved = store.load(), saved.useBase64 == useBase64 else {
            session = nil
            sessionChecked = false
            state = .needsPairing
            return state
        }
        session = saved
        if await savedSessionIsKnown() {
            sessionChecked = true
            state = .paired
        } else {
            session = nil
            store.save(nil)
            state = .needsPairing
        }
        return state
    }

    /// A new helper doesn't answer a session it doesn't know, it just stays silent, and Apple's own
    /// extension starts over on every hello. So a saved pairing only counts once this helper has answered.
    private func savedSessionIsKnown() async -> Bool {
        let site = "doorman.invalid"
        do {
            _ = try await encrypted(AppleCommand.loginNames, qid: "CmdGetLoginNames4URL", body: ["ACT": 5, "URL": site], url: site, timeout: sessionCheckTimeout)
            return true
        } catch {
            return false
        }
    }

    /// Makes macOS show its 6-digit PIN.
    public func beginPairing() async throws {
        let client = SRPClient(useBase64: useBase64)
        srp = client
        serverHello = nil
        let pake: [String: Any] = ["TID": client.tid, "MSG": 0, "A": client.serialize(client.A.bytes), "VER": "1.0", "PROTO": [1]]
        let msg = try Self.jsonString(["QID": "m0", "PAKE": try Self.base64JSON(pake), "HSTBRSR": browserName])
        let reply = try await request(AppleCommand.handshake, ["cmd": AppleCommand.handshake, "msg": msg], timeout: 30)
        let answer = try Self.pake(in: reply)
        guard answer["TID"] as? String == client.tid else { throw AppleProtocolError.badMessage("reply for another session") }
        if let code = Self.int(answer["ErrCode"]), code != 0 { throw AppleProtocolError.badMessage("helper error \(code)") }
        guard Self.int(answer["MSG"]) == 1, let saltString = answer["s"] as? String, let bString = answer["B"] as? String,
              let salt = client.deserialize(saltString), let bBytes = client.deserialize(bString) else {
            throw AppleProtocolError.badMessage("unexpected hello")
        }
        guard Self.int(answer["PROTO"]) == 1 else { throw AppleProtocolError.badMessage("helper offered an old protocol") }
        serverHello = (salt, BigUInt(bytes: bBytes))
        state = .waitingForPIN
    }

    public func finishPairing(pin: String) async throws {
        guard let client = srp, let hello = serverHello else { throw AppleProtocolError.notPaired }
        let proof = try client.proof(pin: pin, salt: hello.salt, B: hello.B)
        let pake: [String: Any] = ["TID": client.tid, "MSG": 2, "M": client.serialize(proof.M, prefix: false)]
        let msg = try Self.jsonString(["QID": "m2", "PAKE": try Self.base64JSON(pake), "HSTBRSR": browserName])
        let reply = try await request(AppleCommand.handshake, ["cmd": AppleCommand.handshake, "msg": msg], timeout: 30)
        let answer = try Self.pake(in: reply)
        guard answer["TID"] as? String == client.tid else { throw AppleProtocolError.badMessage("reply for another session") }
        let code = Self.int(answer["ErrCode"]) ?? -1
        if code == 1 {
            state = .needsPairing
            srp = nil
            serverHello = nil
            throw AppleProtocolError.wrongPIN
        }
        guard code == 0, let hamk = (answer["HAMK"] as? String).flatMap(client.deserialize), hamk == proof.HAMK else {
            state = .needsPairing
            throw AppleProtocolError.serverProofFailed
        }
        let saved = AppleSession(tid: client.tid, key: Data(proof.sessionKey.prefix(16)), useBase64: useBase64)
        session = saved
        sessionChecked = true
        store.save(saved)
        srp = nil
        serverHello = nil
        state = .paired
    }

    public func cancelPairing() async {
        srp = nil
        serverHello = nil
        state = .needsPairing
        if let data = try? JSONSerialization.data(withJSONObject: ["cmd": AppleCommand.cancelPairing]) { try? await transport.send(data) }
    }

    public func forgetPairing() {
        session = nil
        sessionChecked = false
        store.save(nil)
        state = .needsPairing
    }

    // MARK: Asking

    private func encrypted(_ cmd: Int, qid: String, body: [String: Any], url: String?, timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard let session else { throw AppleProtocolError.notPaired }
        let smsg = try session.smsg(body)
        let payload = try Self.jsonString(["QID": qid, "SMSG": smsg])
        var out: [String: Any] = ["cmd": cmd, "tabId": 0, "frameId": 0, "payload": payload]
        if let url { out["url"] = url }
        let reply: [String: Any]
        do {
            // The helper can show its own Touch ID sheet here, which is why the timeout is long.
            reply = try await request(cmd, out, timeout: timeout)
        } catch AppleProtocolError.notPaired {
            throw AppleProtocolError.notPaired
        }
        var payloadObject = reply["payload"]
        if let s = payloadObject as? String { payloadObject = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        guard let dict = payloadObject as? [String: Any] else {
            // A bare status with no payload is how the helper answers a session it doesn't know.
            if Self.int(reply["STATUS"]) == 9 { return try invalidSession() }
            throw AppleProtocolError.badMessage("no payload")
        }
        var smsgObject = dict["SMSG"]
        if let s = smsgObject as? String { smsgObject = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        guard let smsgDict = smsgObject as? [String: Any], let sdata = smsgDict["SDATA"] as? String else {
            throw AppleProtocolError.badMessage("no SMSG")
        }
        guard smsgDict["TID"] as? String == session.tid else { throw AppleProtocolError.badMessage("reply for another session") }
        let plain: Data
        do {
            plain = try session.open(sdata: sdata)
        } catch {
            return try invalidSession()
        }
        guard let decoded = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw AppleProtocolError.badMessage("bad plaintext")
        }
        if Self.int(decoded["STATUS"]) == 9 { return try invalidSession() }
        return decoded
    }

    private func invalidSession() throws -> [String: Any] {
        session = nil
        sessionChecked = false
        store.save(nil)
        state = .needsPairing
        throw AppleProtocolError.notPaired
    }

    private static func entries(_ decoded: [String: Any]) -> [[String: Any]] {
        if let list = decoded["Entries"] as? [[String: Any]] { return list }
        return decoded.filter { $0.key.hasPrefix("Entry_") }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .compactMap { $0.value as? [String: Any] }
    }

    /// Login names saved for a site. No passwords come back from this, which is what Settings uses.
    public func loginNames(site: String) async throws -> [ApplePasswordEntry] {
        try await lookup(site: site).entries
    }

    /// The saved logins for a site, and whether Apple will ask for Touch ID before handing over a password.
    public func lookup(site: String) async throws -> AppleLookup {
        let decoded = try await encrypted(AppleCommand.loginNames, qid: "CmdGetLoginNames4URL", body: ["ACT": 5, "URL": site], url: site, timeout: 30)
        let entries = Self.entries(decoded).compactMap { e -> ApplePasswordEntry? in
            guard let usr = e["USR"] as? String, usr != "Passwords\u{a0}not\u{a0}saved" else { return nil }
            return ApplePasswordEntry(username: usr, sites: e["sites"] as? [String] ?? [])
        }
        return AppleLookup(entries: entries, requiresTouchID: decoded["RequiresUserAuthenticationToFill"] as? Bool ?? false)
    }

    public func credential(site: String, username: String) async throws -> Credential? {
        let decoded = try await encrypted(AppleCommand.password, qid: "CmdGetPassword4LoginName", body: ["ACT": 2, "URL": site, "USR": username], url: site)
        let list = Self.entries(decoded)
        guard let hit = list.first(where: { ($0["USR"] as? String) == username }), let pwd = hit["PWD"] as? String, !pwd.isEmpty else { return nil }
        // Replies only carry a command number, so a late answer about another site could land here. The
        // entry has to name this site. Apple's own extension relies on the same field.
        guard let sites = hit["sites"] as? [String], sites.contains(where: { Approval.siteMatches(site: $0, host: site) }) else { return nil }
        return Credential(username: username, password: Secret(pwd))
    }

    public func authenticatorCode(url: String, username: String) async throws -> Secret? {
        var body: [String: Any] = ["ACT": 2, "TYPE": "oneTimeCodes", "frameURLs": [url]]
        if !username.isEmpty { body["username"] = username }
        let decoded = try await encrypted(AppleCommand.getCode, qid: "CmdDidFillOneTimeCode", body: body, url: nil)
        // Only this login's code. Anything else comes back as nothing, and you get asked to type it.
        let hit = Self.entries(decoded).first { ($0["source"] as? String ?? "totp") == "totp" && ($0["username"] as? String) == username }
        return (hit?["code"] as? String).map { Secret($0) }
    }

    // MARK: JSON helpers

    static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func base64JSON(_ object: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }

    static func pake(in reply: [String: Any]) throws -> [String: Any] {
        var payload = reply["payload"]
        if let s = payload as? String { payload = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        guard let dict = payload as? [String: Any], let pake = dict["PAKE"] as? String, let data = Data(base64Encoded: pake),
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppleProtocolError.badMessage("no PAKE")
        }
        return answer
    }
}
