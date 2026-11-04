import Foundation
import Darwin
import DoormanCore

// A real end-to-end run: real Chrome, the real extension, the real native host, the real MCP server, and
// the demo site. The one fake is the approver below, because nobody's here to press Touch ID. This binary
// is dev only and is never copied into Doorman.app.
//
// Usage: swift run doorman-e2e   (from the repo root)

let root = FileManager.default.currentDirectoryPath
let port = 8791
let base = "http://localhost:\(port)"
let demoPassword = "demo-password-1234"
let demoCode = "424242"
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("doorman-e2e-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let socketPath = "/tmp/doorman-e2e-\(getpid()).sock"
let buildDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path

final class RecordingApprover: Approver, @unchecked Sendable {
    let requests = LockedValue<[ApprovalRequest]>([])
    let denyAccounts: Set<String>
    init(deny: Set<String>) { denyAccounts = deny }
    func approve(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.value = requests.value + [request]
        if request.accounts.contains(where: { denyAccounts.contains($0.name) }) { return .denied }
        return .approved(accountID: request.accounts[0].id)
    }
    func askForCode(app: String, account: String) async -> Secret? { nil }
}

/// Wrong password for the one account meant to get it wrong.
struct DemoPasswords: PasswordSource {
    func credential(for account: Account, host: String) async throws -> Credential {
        Credential(username: "demo@doorman.test", password: Secret(account.name == "Wrong password" ? "not-the-password-9999" : demoPassword))
    }
    func authenticatorCode(for account: Account, url: URL) async throws -> Secret? { Secret(demoCode) }
    /// The demo site answers on 127.0.0.1 too, which no app is set up for: a site you haven't added.
    func loginNames(site: String) async throws -> [String] { site == "127.0.0.1" ? ["demo@doorman.test"] : [] }
}

func demoSettings() -> DoormanSettings {
    var roles: [Role] = []
    var accounts: [Account] = []
    func add(_ path: String, _ signIn: SignInMethod, code: CodeSource = .authenticator, rule: ApprovalRule = .everyTime, account: String? = nil) {
        let role = Role(name: path, path: "/\(path)", signIn: signIn, codeIfAsked: code, mailSender: signIn == .password ? "" : "codes@doorman.test")
        roles.append(role)
        accounts.append(Account(name: account ?? path, roleID: role.id, login: "demo@doorman.test",
                                credential: signIn == .password ? .stored : .none, approval: rule))
    }
    add("password", .password)
    add("totp", .password)
    add("twostep", .password, rule: .noPopup)
    add("emailcode", .emailCode)
    add("split", .emailCode)
    add("emaillink", .emailLink, code: .none)
    add("controlled", .password)
    add("captcha", .password)
    add("redirect", .password)
    return DoormanSettings(apps: [AppProfile(name: "Demo", host: "localhost:\(port)", isTest: true, roles: roles, accounts: accounts)])
}

var settings = demoSettings()
// Same path, second role name, for the failure cases.
do {
    let passwordRole = settings.apps[0].roles[0]
    settings.apps[0].accounts.append(Account(name: "Wrong password", roleID: passwordRole.id, login: "demo@doorman.test", credential: .stored))
    settings.apps[0].accounts.append(Account(name: "Denied", roleID: passwordRole.id, login: "demo@doorman.test", credential: .stored))
}
let snapshot = settings

let approver = RecordingApprover(deny: ["Denied"])
let activity = ActivityLog()
let hub = ConnectionHub()
let hostBinary = "\(buildDir)/doorman-host"
let fillExtension = "\(root)/extension/fill"
var timing = EngineTiming()
timing.pagePoll = 0.15
timing.settlePolls = 6
timing.rejectAfter = 2.5
timing.mailPoll = 0.25
timing.mailWindow = 15
timing.overall = 40
let chromeEnv = ["DOORMAN_SOCKET": socketPath]
let sessions = HiddenSessionRunner(hub: hub, hostBinary: hostBinary, fillExtensionPath: fillExtension, directory: scratch.appendingPathComponent("sessions"), environment: chromeEnv, lifetime: 300)
let engine = SignInEngine(settings: { .usable(snapshot) }, approver: approver, passwords: DemoPasswords(), mail: RoutingMailSource(real: NoMailSource(), demo: DemoMailSource(port: port)),
                          adapters: { hub.adapters }, sessionFiles: sessions, activity: activity, timing: timing)
let daemon = Daemon(socketPath: socketPath, hub: hub, engine: engine, settings: { .usable(snapshot) }, expectedHostPath: hostBinary)
try daemon.start()

// The demo site.
let demo = Process()
demo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
demo.arguments = ["node", "\(root)/demo/server.mjs"]
demo.environment = ProcessInfo.processInfo.environment.merging(["DEMO_PORT": String(port)]) { $1 }
demo.standardOutput = FileHandle.nullDevice
try demo.run()

// The MCP server, exactly as an agent starts it.
let mcp = Process()
let mcpIn = Pipe(), mcpOut = Pipe()
mcp.executableURL = URL(fileURLWithPath: "\(buildDir)/doorman-mcp")
mcp.environment = ProcessInfo.processInfo.environment.merging(["DOORMAN_SOCKET": socketPath]) { $1 }
mcp.standardInput = mcpIn
mcp.standardOutput = mcpOut
try mcp.run()

let everythingTheAgentSaw = LockedValue(Data())
final class MCPClient: @unchecked Sendable {
    private var next = 1
    private var buffer = Data()
    func call(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let id = next
        next += 1
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params] as [String: Any])
        mcpIn.fileHandleForWriting.write(data + Data([0x0A]))
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<i)
                buffer.removeSubrange(buffer.startIndex...i)
                everythingTheAgentSaw.value = everythingTheAgentSaw.value + line + Data([0x0A])
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["id"] as? Int == id { return o }
                continue
            }
            let chunk = mcpOut.fileHandleForReading.availableData
            if chunk.isEmpty { return [:] }
            buffer.append(chunk)
        }
    }
    func tool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        let reply = call("tools/call", ["name": name, "arguments": args])
        let content = ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
    }
}
let client = MCPClient()

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String) {
    if ok {
        passed += 1
        print("  ok    \(label)")
    } else {
        failed += 1
        print("  FAIL  \(label)")
    }
    fflush(stdout)
}

func cleanupAndExit() -> Never {
    mcp.terminate()
    demo.terminate()
    daemon.stop()
    try? FileManager.default.removeItem(at: scratch)
    print("\n\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

func runAll() async throws {
    try await Task.sleep(nanoseconds: 500_000_000)
    guard let binary = HiddenChrome.findBrowser() else {
        print("No Chrome found")
        failed += 1
        return
    }
    let chrome = HiddenChrome(binary: binary, profile: scratch.appendingPathComponent("chrome"), extensions: [fillExtension],
                              nativeHosts: [.init(name: DoormanConstants.nativeHostName, manifest: nativeHostManifest(path: hostBinary, allowedExtensionIDs: [DoormanConstants.fillExtensionID]))],
                              environment: chromeEnv)
    try await chrome.start()
    defer { chrome.stop() }

    print("Connecting")
    var connected = false
    for _ in 0..<100 {
        if hub.browserCount > 0 { connected = true; break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    check(connected, "the extension connected through the native host, and the peer check let it in")
    guard connected, let adapter = hub.adapters.first as? ExtensionAdapter else { return }

    _ = client.call("initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "e2e-agent", "version": "1"], "capabilities": [:]])
    let list = client.call("tools/list", [:])
    let names = (((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    check(Set(names) == ["sign_in", "check_sign_in", "sign_in_options", "doorman_status"], "MCP lists exactly four tools, none of which returns a secret")

    /// Opens the page, signs in through MCP, returns the agent's answer and the page's final address.
    func signIn(_ scenario: String, account: String? = nil, role: String? = nil, expect: String, reason: String? = nil, label: String) async throws -> String {
        let url = "\(base)/\(scenario)/login"
        try await adapter.closeDemoTabs(host: "localhost:\(port)")
        _ = try await adapter.open(url: URL(string: url)!)
        try await Task.sleep(nanoseconds: 400_000_000)
        var args: [String: Any] = ["url": url, "reason": "e2e \(scenario)"]
        if let account { args["account"] = account }
        if let role { args["role"] = role }
        let answer = client.tool("sign_in", args)
        let status = answer["status"] as? String ?? "none"
        let why = answer["reason"] as? String ?? ""
        var ok = status == expect
        if let reason { ok = ok && why == reason }
        let tabs = (try? await adapter.tabs()) ?? []
        let final = tabs.first(where: { $0.active })?.url ?? tabs.first?.url ?? ""
        check(ok, "\(label): \(status)\(why.isEmpty ? "" : " (\(why))")")
        return final
    }

    print("\nSign-ins that should work")
    var at = try await signIn("password", account: "password", expect: "signed_in", label: "password only")
    check(at.hasSuffix("/password/home"), "  landed on the signed-in page")
    at = try await signIn("totp", expect: "signed_in", label: "password, then an authenticator code the site asked for")
    check(at.hasSuffix("/totp/home"), "  landed on the signed-in page")
    let promptsBefore = approver.requests.value.count
    at = try await signIn("twostep", expect: "signed_in", label: "login name, then password on the next page, on a no-popup account")
    check(at.hasSuffix("/twostep/home"), "  landed on the signed-in page")
    check(approver.requests.value.count == promptsBefore, "  a no-popup account skipped the prompt")
    at = try await signIn("emailcode", expect: "signed_in", label: "email code, read from the mailbox")
    check(at.hasSuffix("/emailcode/home"), "  landed on the signed-in page")
    at = try await signIn("split", expect: "signed_in", label: "email code typed into six separate boxes")
    check(at.hasSuffix("/split/home"), "  landed on the signed-in page")
    at = try await signIn("emaillink", expect: "signed_in", label: "email link opened in the same tab")
    check(at.hasSuffix("/emaillink/home"), "  landed on the signed-in page")
    at = try await signIn("controlled", expect: "signed_in", label: "a page that only reads input events, like React")
    check(at.hasSuffix("/controlled/home"), "  landed on the signed-in page")

    print("\nSign-ins that should stop")
    at = try await signIn("password", account: "Wrong password", expect: "failed", reason: Reason.passwordRejected, label: "wrong password isn't retried")
    at = try await signIn("password", account: "Denied", expect: "denied", reason: Reason.userDenied, label: "you denied it")
    check(at.hasSuffix("/password/login"), "  nothing was submitted")
    _ = try await signIn("captcha", expect: "needs_you", reason: Reason.captcha, label: "CAPTCHA handed back")
    _ = try await signIn("redirect", expect: "needs_you", reason: Reason.wrongSite, label: "site redirected to another host, so it stopped")
    let stats = try await URLSession.shared.data(from: URL(string: "\(base)/__stats")!).0
    check(String(decoding: stats, as: UTF8.self).contains("\"phishPosts\":0"), "  the other host got nothing")

    print("\nA site you haven't added, using a saved login")
    try await adapter.closeDemoTabs(host: "localhost:\(port)")
    let plainURL = "http://127.0.0.1:\(port)/password/login"
    _ = try await adapter.open(url: URL(string: plainURL)!)
    try await Task.sleep(nanoseconds: 400_000_000)
    let promptsBeforeUnadded = approver.requests.value.count
    let unadded = client.tool("sign_in", ["url": plainURL, "reason": "e2e unadded"])
    check(unadded["status"] as? String == "signed_in", "signed in with no app set up for it: \(unadded["status"] ?? "none") \(unadded["reason"] ?? "")")
    check(approver.requests.value.count == promptsBeforeUnadded + 1, "  it asked first")
    check(approver.requests.value.last?.roleWarning == "You haven't added this site", "  the prompt said you hadn't added it")
    let afterUnadded = (try? await adapter.tabs())?.first(where: { $0.active })?.url ?? ""
    check(afterUnadded.hasSuffix("/password/home"), "  landed on the signed-in page")

    print("\nWhat an agent can't do")
    let unknown = client.tool("sign_in", ["url": "https://bank.example.com/login"])
    check(unknown["reason"] as? String == Reason.noWindow, "a site with no open window goes nowhere")
    try await adapter.closeDemoTabs(host: "localhost:\(port)")
    let noTab = client.tool("sign_in", ["url": "\(base)/password/login"])
    check(noTab["reason"] as? String == Reason.noWindow, "no open window on the site: asks you to open one")
    let options = client.tool("sign_in_options", [:])
    let optionsText = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
    check(optionsText.contains("password") && !optionsText.contains("demo@doorman.test"), "options list names, with no login names")

    // Something pretending to be a browser: right socket, wrong program.
    let fake = try connectUnixSocket(path: socketPath)
    let closedFlag = LockedValue(false)
    let sawPassword = LockedValue(false)
    fake.onClose = { closedFlag.value = true }
    fake.onLine = { if String(decoding: $0, as: UTF8.self).contains(demoPassword) { sawPassword.value = true } }
    fake.start()
    fake.send(json: ["hostHello": ["origin": "chrome-extension://\(DoormanConstants.fillExtensionID)/"]])
    try await Task.sleep(nanoseconds: 500_000_000)
    check(closedFlag.value && !sawPassword.value, "a process pretending to be the browser is disconnected")
    check(hub.browserCount == 1, "  and isn't counted as a browser")

    do {
        _ = try await adapter.exportSession(tab: "1", expectedHost: "localhost:\(port)")
        check(false, "the normal extension refuses to hand over cookies")
    } catch {
        check("\(error)".contains("not_available_here"), "the normal extension refuses to hand over cookies")
    }

    print("\nSession file, for browsers an agent starts itself")
    let saved = client.tool("sign_in", ["url": "\(base)/password/login", "session_file": true, "account": "password"])
    check(saved["status"] as? String == "signed_in", "signed in inside a hidden browser")
    if let path = saved["sessionFile"] as? String, let data = FileManager.default.contents(atPath: path),
       let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        let cookies = (state["cookies"] as? [[String: Any]]) ?? []
        check(cookies.contains { $0["name"] as? String == "demo_session" }, "the file holds the site's session cookie")
        check(!String(decoding: data, as: UTF8.self).contains(demoPassword), "the file doesn't hold the password")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        check(attrs[.posixPermissions] as? Int == 0o600, "the file is owner-only")
        check(saved["sessionFileExpires"] != nil, "the answer says when it expires")
    } else {
        check(false, "the answer names a readable session file")
    }
    check(hub.browserCount == 1, "the hidden browser is gone")

    print("\nThe big one")
    let seen = String(decoding: everythingTheAgentSaw.value, as: UTF8.self)
    check(!seen.contains(demoPassword), "the demo password appears nowhere in anything the agent received")
    check(!seen.contains(demoCode), "the authenticator code appears nowhere in anything the agent received")
    let mailData = try await URLSession.shared.data(from: URL(string: "\(base)/__mail")!).0
    let mailed = (try? JSONSerialization.jsonObject(with: mailData)) as? [[String: Any]] ?? []
    var codesFound = 0
    for item in mailed {
        guard let raw = item["raw"] as? String else { continue }
        if let r = raw.range(of: #"code is (\d{6})"#, options: .regularExpression) {
            codesFound += 1
            let digits = raw[r].filter(\.isNumber)
            if seen.contains(String(digits)) { check(false, "emailed code \(digits) reached the agent") }
        }
        if let r = raw.range(of: #"token=[0-9a-f-]+"#, options: .regularExpression), seen.contains(String(raw[r])) {
            check(false, "the sign-in link's token reached the agent")
        }
    }
    check(codesFound >= 2, "checked \(codesFound) real emailed codes, and none reached the agent")
    let log = activity.recent()
    check(log.count >= 12, "the activity log recorded every attempt (\(log.count))")
    let logText = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
    check(!logText.contains(demoPassword) && !logText.contains(demoCode), "the activity log holds no secrets")
    check(log.contains { $0.agent == "e2e-agent" }, "the log names the agent")
    check(approver.requests.value.first?.agent == "e2e-agent" && approver.requests.value.first?.agentReason == "e2e password", "the prompt showed the agent and its reason")
}

/// `doorman-e2e --apple-probe`: does Apple's helper answer through hidden Chrome on this Mac? Sends only
/// the hello message. No PIN appears and no password is read.
func appleProbe() async {
    let store = InMemoryAppleSessionStore()
    let connection = AppleConnection(hub: hub, hostBinary: hostBinary, relayExtensionPath: "\(root)/extension/apple-bridge", store: store, environment: chromeEnv)
    do {
        let state = try await connection.connect()
        print("Apple helper answered. State: \(state)")
        print("Capabilities: \(await connection.client.lastCapabilitiesSummary)")
    } catch {
        print("Apple helper probe failed: \(error)")
        failed += 1
    }
    connection.disconnect()
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        if CommandLine.arguments.contains("--apple-probe") {
            await appleProbe()
            done.signal()
            return
        }
        try await runAll()
    } catch {
        print("e2e stopped: \(error)")
        failed += 1
    }
    done.signal()
}
if done.wait(timeout: .now() + 300) == .timedOut {
    print("e2e timed out")
    failed += 1
}
cleanupAndExit()
