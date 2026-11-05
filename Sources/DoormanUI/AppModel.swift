import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import DoormanCore

/// Paths that differ between the installed app and a development run.
public struct AppPaths {
    public var hostBinary: String
    public var extensionRoot: String
    public var mcpBinary: String

    public static func detect() -> AppPaths {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return AppPaths(hostBinary: bundle.appendingPathComponent("Contents/MacOS/doorman-host").path,
                            extensionRoot: bundle.appendingPathComponent("Contents/Resources/extension").path,
                            mcpBinary: bundle.appendingPathComponent("Contents/MacOS/doorman-mcp").path)
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let root = FileManager.default.currentDirectoryPath
        return AppPaths(hostBinary: "\(exe)/doorman-host", extensionRoot: "\(root)/extension", mcpBinary: "\(exe)/doorman-mcp")
    }
}

public enum SidebarItem: Hashable {
    case app(UUID)
    case start, activity, email, browsers, apple
}

@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    public let approvals = ApprovalCenter()
    @Published public var saved = DoormanSettings()
    @Published public var draft = DoormanSettings()
    @Published public var changedOutside = false
    @Published public var loadError: String?
    @Published public var selection: SidebarItem?
    @Published public var activity: [ActivityEntry] = []
    @Published public var browserCount = 0
    @Published public var appleState: AppleConnectionState = .notConnected
    @Published public var appleMessage = ""
    @Published public var saveMessage = ""
    @Published public var mailMessage = ""
    /// Typed into Settings, and only written to the Keychain on Save.
    @Published public var pendingPasswords: [UUID: String] = [:]
    @Published public var imapPasswordDraft = ""
    @Published public var gmailSecretDraft = ""
    @Published public var demoSiteRunning = false

    public var isDirty: Bool { draft != saved || !pendingPasswords.isEmpty }
    public var problems: [String] { SettingsValidator.problems(draft) }

    private var approvalsChange: AnyCancellable?
    private let snapshot = LockedValue<SettingsSnapshot>(.usable(DoormanSettings()))
    private var store: SettingsStore?
    private var activityLog = ActivityLog()
    private var hub: ConnectionHub?
    private var daemon: Daemon?
    private var appleConnection: AppleConnection?
    private let paths = AppPaths.detect()
    private let currentMail = LockedValue<MailSource>(NoMailSource())
    private var refreshTimer: Timer?
    private var sessions: HiddenSessionRunner?
    private var ticks = 0
    private var started = false

    public init() {
        // The menu bar icon watches the approvals object through this one.
        approvalsChange = approvals.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public func start() {
        guard !started else { return }
        started = true
        // A second copy would take over the socket, so it just leaves.
        let mine = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != mine }) {
            NSApp.terminate(nil)
            return
        }
        if let id = Bundle.main.bundleIdentifier { DoormanNetwork.removeOldCaches(bundleID: id) }
        let directory = DoormanConstants.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = SettingsStore(directory: directory, keys: KeychainSigningKey(), generations: KeychainGenerationStore())
        self.store = store
        load(store)

        activityLog = ActivityLog(file: directory.appendingPathComponent("activity.jsonl"))
        activity = activityLog.recent()
        activityLog.onAppend = { [weak self] entry in
            Task { @MainActor in self?.announce(entry) }
        }

        let hub = ConnectionHub()
        self.hub = hub
        hub.onChange = { [weak self] in
            Task { @MainActor in self?.browserCount = hub.browserCount }
        }
        let apple = AppleConnection(hub: hub, hostBinary: paths.hostBinary, relayExtensionPath: "\(paths.extensionRoot)/apple-bridge",
                                    store: KeychainAppleSessionStore(),
                                    profile: directory.appendingPathComponent("hidden-chrome"))
        appleConnection = apple
        rebuildMail()

        let snapshot = self.snapshot
        let mailBox = currentMail
        let sessions = HiddenSessionRunner(hub: hub, hostBinary: paths.hostBinary, fillExtensionPath: "\(paths.extensionRoot)/fill",
                                           directory: directory.appendingPathComponent("sessions"))
        sessions.sweep()
        self.sessions = sessions
        let engine = SignInEngine(
            settings: { snapshot.value },
            approver: AppApprover(center: approvals),
            passwords: AppPasswordSource(apple: apple),
            mail: RoutingMailSource(real: DeferredMailSource(box: mailBox)),
            adapters: { [ax = AccessibilityAdapter()] in
                var list = hub.adapters
                if case let .usable(current) = snapshot.value, current.useAccessibility, AccessibilityProbe.isTrusted { list.append(ax) }
                return list
            },
            sessionFiles: sessions,
            activity: activityLog,
            progress: { [approvals] text in
                Task { @MainActor in approvals.show(.init(text: text, detail: "", kind: .working), hideAfter: nil) }
            })
        let daemon = Daemon(socketPath: DoormanConstants.socketPath, hub: hub, engine: engine, settings: { snapshot.value }, expectedHostPath: paths.hostBinary,
                            statusProvider: {
                                var out: [String: Any] = ["accessibility": AccessibilityProbe.check().asDictionary]
                                if case let .usable(current) = snapshot.value { out["use_accessibility"] = current.useAccessibility } else { out["settings_need_review"] = true }
                                return out
                            })
        self.daemon = daemon
        do {
            try daemon.start()
        } catch {
            loadError = "Doorman couldn't open its socket: \(error)"
        }
        installNativeHost()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if KeychainAppleSessionStore().load() != nil {
            Task { await connectApple() }
        }
    }

    /// The corner note when a sign-in ends, so you can see it worked, or why it didn't.
    private func announce(_ entry: ActivityEntry) {
        let place = entry.app.isEmpty ? entry.host : entry.app
        switch entry.status {
        case .filled:
            approvals.show(.init(text: "Filled in \(place)", detail: "for \(entry.agent)", kind: .success), hideAfter: 5)
        case .nothingToFill:
            approvals.show(.init(text: "Nothing to fill on \(place)", detail: entry.agent, kind: .success), hideAfter: 3)
        case .denied:
            approvals.show(.init(text: "Denied \(place)", detail: "", kind: .problem), hideAfter: 3)
        case .pending:
            break
        case .needsYou where entry.reason == Reason.appleNotPaired:
            approvals.show(.init(text: "Apple Passwords needs pairing", detail: "In Doorman, open Apple Passwords and type the code macOS shows", kind: .problem), hideAfter: 10)
        case .needsYou where entry.reason == Reason.noApp:
            approvals.show(.init(text: "Couldn't sign in to \(place)", detail: "It isn't added, and Apple Passwords has no login for it", kind: .problem), hideAfter: 8)
        default:
            approvals.show(.init(text: "Couldn't sign in to \(place)", detail: entry.reason.replacingOccurrences(of: "_", with: " "), kind: .problem), hideAfter: 8)
        }
    }

    public func stop() {
        appleConnection?.disconnect()
        daemon?.stop()
    }

    private func refresh() {
        ticks += 1
        if ticks % 15 == 0 { sessions?.sweep() }
        activity = activityLog.recent()
        if let hub { browserCount = hub.browserCount }
        // A sign-in can find out that the pairing has gone, and this page should say so too.
        if let apple = appleConnection {
            Task { [weak self] in
                let state = await apple.client.state
                if self?.appleState != state { self?.appleState = state }
            }
        }
        // A change on disk while running counts just like one at launch.
        if let store, !isDirty, case .changedOutside = (try? store.load()) ?? .empty, !changedOutside {
            load(store)
        }
    }

    private func load(_ store: SettingsStore) {
        do {
            switch try store.load() {
            case .empty:
                apply(DoormanSettings())
            case let .ok(settings):
                apply(settings)
            case let .changedOutside(settings):
                changedOutside = true
                saved = settings ?? DoormanSettings()
                draft = saved
                snapshot.value = .changedOutside
            }
        } catch {
            loadError = "Doorman couldn't read its settings: \(error)"
            snapshot.value = .changedOutside
        }
        if selection == nil { selection = .start }
    }

    private func apply(_ settings: DoormanSettings) {
        saved = settings
        draft = settings
        changedOutside = false
        snapshot.value = .usable(settings)
    }

    // MARK: Saving

    /// Every save takes a tap, because an agent with screen control could click through this window.
    public func save() {
        guard problems.isEmpty, let store else { return }
        let next = draft
        let passwords = pendingPasswords
        let wasChangedOutside = changedOutside
        Task {
            guard await TouchID.confirm(reason: wasChangedOutside ? "accept Doorman's settings as they are now" : "save Doorman's settings") else {
                saveMessage = "Not saved. Touch ID didn't complete."
                return
            }
            do {
                for (id, value) in passwords where !value.isEmpty {
                    try AppPasswordSource.storePassword(Secret(value), accountID: id)
                }
                try store.save(next)
                apply(next)
                pendingPasswords = [:]
                saveMessage = "Saved"
                rebuildMail()
            } catch {
                saveMessage = "Couldn't save: \(error)"
            }
        }
    }

    public func revert() {
        draft = saved
        pendingPasswords = [:]
        saveMessage = ""
    }

    public func discardAndStartEmpty() {
        guard let store else { return }
        Task {
            guard await TouchID.confirm(reason: "reset Doorman's settings") else { return }
            do {
                try store.save(DoormanSettings())
                apply(DoormanSettings())
                selection = .start
            } catch {
                saveMessage = "Couldn't reset: \(error)"
            }
        }
    }

    /// Pausing stops agents, so it needs no tap. Resuming needs one.
    public func setPaused(_ paused: Bool) {
        // While settings need review nothing can sign in anyway, and saving here would sign the
        // changed file with no tap, which would quietly make it trusted.
        guard let store, !changedOutside else { return }
        var next = saved
        next.paused = paused
        Task {
            if !paused {
                guard await TouchID.confirm(reason: "turn Doorman's sign-ins back on") else { return }
            }
            do {
                try store.save(next)
                saved.paused = paused
                draft.paused = paused
                snapshot.value = .usable(next)
            } catch {
                saveMessage = "Couldn't change that: \(error)"
            }
        }
    }

    // MARK: Editing

    public func addApp() {
        let app = AppProfile(name: "New app", host: "", roles: [Role(name: "Sign-in", path: "/")])
        draft.apps.append(app)
        selection = .app(app.id)
    }

    public func removeApp(_ id: UUID) {
        draft.apps.removeAll { $0.id == id }
        if selection == .app(id) { selection = draft.apps.first.map { .app($0.id) } ?? .start }
    }

    /// Fills in the local demo site so everything can be tried with nothing real at stake.
    public func addDemoApp() {
        let sender = "codes@doorman.test"
        let scenarios: [(String, SignInMethod, CodeSource)] = [
            ("Password", .password, .none), ("Totp", .password, .askMe), ("Twostep", .password, .none), ("Picker", .password, .none), ("Emailcode", .emailCode, .none),
            ("Split", .emailCode, .none), ("Emaillink", .emailLink, .none), ("Controlled", .password, .none), ("Captcha", .password, .none), ("Redirect", .password, .none),
        ]
        var roles: [Role] = []
        var accounts: [Account] = []
        for (name, method, code) in scenarios {
            let role = Role(name: name, path: "/\(name.lowercased())", signIn: method, codeIfAsked: code, mailSender: method == .password ? "" : sender)
            roles.append(role)
            let account = Account(name: "Demo \(name.lowercased())", roleID: role.id, login: "demo@doorman.test",
                                  credential: method == .password ? .stored : .none, approval: .everyTime)
            accounts.append(account)
            if method == .password { pendingPasswords[account.id] = "demo-password-1234" }
        }
        let app = AppProfile(name: "Demo site", host: "localhost:8765", isTest: true, roles: roles, accounts: accounts)
        draft.apps.append(app)
        selection = .app(app.id)
    }

    /// The demo site ships with the source, so only offer it when it's really running.
    public func checkDemoSite() {
        guard let url = URL(string: "http://localhost:8765/") else { return }
        Task {
            let running = (try? await DoormanNetwork.session.data(from: url))?.1 != nil
            demoSiteRunning = running
        }
    }

    /// For another agent's MCP settings, and for Claude Code.
    public var mcpPath: String { mcpPathOverride ?? paths.mcpBinary }
    public var claudeCodeCommand: String { "claude mcp add --scope user doorman -- \"\(mcpPath)\"" }
    /// For screenshots, so they don't show whoever built them.
    public var mcpPathOverride: String?

    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func testAddress(_ address: String, in app: AppProfile?) -> String {
        Resolver.describe(Resolver.resolve(address: address, settings: draft))
    }

    public func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "doorman-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = saved
        copy.mail = MailSettings()
        if let data = try? encoder.encode(copy) { try? data.write(to: url) }
    }

    /// Loads into the draft. It still takes a Save with Touch ID before it's used.
    public func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard let imported = try? JSONDecoder().decode(DoormanSettings.self, from: data) else {
            saveMessage = "That file isn't Doorman settings."
            return
        }
        draft.apps.append(contentsOf: imported.apps)
        selection = imported.apps.first.map { .app($0.id) }
        saveMessage = "Imported. Review it, then save."
    }

    // MARK: Apple Passwords

    public func connectApple() async {
        guard let apple = appleConnection else { return }
        appleMessage = "Connecting…"
        do {
            appleState = try await apple.connect()
            appleMessage = ""
        } catch AppleConnectionError.helperMissing {
            appleMessage = "Apple's password helper isn't on this Mac. It ships with macOS 14 and later."
        } catch AppleConnectionError.noBrowser {
            appleMessage = "Doorman needs Chrome, Brave or Edge installed. Apple's helper only talks to a browser."
        } catch {
            appleMessage = "Couldn't reach Apple's helper: \(error)"
        }
    }

    public func beginApplePairing() async {
        guard let apple = appleConnection else { return }
        appleMessage = ""
        do {
            try await apple.connect()
            try await apple.client.beginPairing()
            appleState = await apple.client.state
            appleMessage = "macOS is showing a 6-digit code. Type it here."
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            appleMessage = "Couldn't start pairing: \(error)"
        }
    }

    public func finishApplePairing(pin: String) async {
        guard let apple = appleConnection else { return }
        do {
            try await apple.client.finishPairing(pin: pin.trimmingCharacters(in: .whitespaces))
            appleState = await apple.client.state
            appleMessage = "Connected to Apple Passwords."
        } catch AppleProtocolError.wrongPIN {
            appleState = await apple.client.state
            appleMessage = "That code didn't match. Start again to get a new one."
        } catch {
            appleState = await apple.client.state
            appleMessage = "Pairing didn't finish: \(error)"
        }
    }

    public func disconnectApple() async {
        guard let apple = appleConnection else { return }
        await apple.client.forgetPairing()
        apple.disconnect()
        appleState = .notConnected
        appleMessage = ""
    }

    /// Login names only. Reading a name doesn't read a password.
    public func appleLogins(site: String) async -> [String] {
        guard let apple = appleConnection else { return [] }
        do {
            guard try await apple.connect() == .paired else {
                appleMessage = "Connect Apple Passwords first."
                return []
            }
            return try await apple.client.loginNames(site: normalizeHost(site)).map(\.username)
        } catch {
            appleMessage = "Couldn't look that up: \(error)"
            return []
        }
    }

    // MARK: Mail

    private func rebuildMail() {
        let mail = saved.mail
        switch mail.provider {
        case .notConnected:
            currentMail.value = NoMailSource()
        case .imap:
            currentMail.value = IMAPMailSource(config: .init(host: mail.imapHost, port: mail.imapPort, username: mail.address, authServer: mail.imapTrustedAuthServer)) {
                Keychain.get(account: "imap-password").map { Secret(String(decoding: $0, as: UTF8.self)) }
            }
        case .gmail:
            currentMail.value = GmailMailSource(clientID: mail.gmailClientID, clientSecret: {
                Keychain.get(account: "gmail-client-secret").map { String(decoding: $0, as: UTF8.self) } ?? ""
            }, store: KeychainGmailStore(), hasStoredTokens: { Keychain.has(account: "gmail-tokens") })
        }
    }

    public var hasIMAPPassword: Bool { Keychain.has(account: "imap-password") }
    public var hasGmailTokens: Bool { Keychain.has(account: "gmail-tokens") }

    public func saveIMAPPassword() {
        guard !imapPasswordDraft.isEmpty else { return }
        let value = imapPasswordDraft
        Task {
            guard await TouchID.confirm(reason: "save the mailbox password") else { return }
            try? Keychain.set(Data(value.utf8), account: "imap-password")
            imapPasswordDraft = ""
            mailMessage = "Password saved."
            objectWillChange.send()
        }
    }

    public func checkIMAP() async {
        let mail = draft.mail
        let source = IMAPMailSource(config: .init(host: mail.imapHost, port: mail.imapPort, username: mail.address)) {
            Keychain.get(account: "imap-password").map { Secret(String(decoding: $0, as: UTF8.self)) }
        }
        mailMessage = "Checking…"
        do {
            let count = try await source.check()
            mailMessage = "Connected. \(count) messages in the last day, none of them read."
        } catch MailSourceError.notConnected {
            mailMessage = "Enter and save the password first."
        } catch let MailSourceError.failed(text) {
            mailMessage = text
        } catch {
            mailMessage = "Couldn't connect."
        }
    }

    public func connectGmail() {
        let clientID = draft.mail.gmailClientID.trimmingCharacters(in: .whitespaces)
        let secret = gmailSecretDraft
        guard !clientID.isEmpty, !secret.isEmpty else {
            mailMessage = "Enter the client ID and secret first."
            return
        }
        mailMessage = "Finish signing in to Google in your browser…"
        Task {
            guard await TouchID.confirm(reason: "connect Gmail") else {
                mailMessage = ""
                return
            }
            do {
                let tokens = try await GmailAuthorizer.connect(clientID: clientID, clientSecret: secret) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                KeychainGmailStore().save(tokens)
                try? Keychain.set(Data(secret.utf8), account: "gmail-client-secret")
                gmailSecretDraft = ""
                mailMessage = "Gmail connected, read-only. Save your settings to start using it."
                objectWillChange.send()
            } catch {
                mailMessage = "Gmail didn't connect: \(error)"
            }
        }
    }

    public func disconnectMail() {
        Keychain.delete(account: "imap-password")
        KeychainGmailStore().save(nil)
        Keychain.delete(account: "gmail-client-secret")
        mailMessage = "Disconnected."
        objectWillChange.send()
    }

    // MARK: Browsers

    public var extensionFolder: URL { DoormanConstants.supportDirectory.appendingPathComponent("chrome-extension") }

    /// Tells Chrome where the native host is, and keeps a copy of the extension somewhere easy to pick.
    public func installNativeHost() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let browsers = ["Google/Chrome", "Google/Chrome Canary", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Chromium"]
        let manifest = nativeHostManifest(path: paths.hostBinary, allowedExtensionIDs: [DoormanConstants.fillExtensionID])
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return }
        for browser in browsers {
            let base = home.appendingPathComponent("Library/Application Support/\(browser)")
            guard fm.fileExists(atPath: base.path) else { continue }
            let dir = base.appendingPathComponent("NativeMessagingHosts")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(DoormanConstants.nativeHostName).json"))
        }
        // Only when it changed: Chrome reads this folder, and it shouldn't vanish under a loaded extension.
        let source = URL(fileURLWithPath: "\(paths.extensionRoot)/fill")
        let same = ["manifest.json", "background.js"].allSatisfy {
            guard let a = fm.contents(atPath: source.appendingPathComponent($0).path) else { return false }
            return a == fm.contents(atPath: extensionFolder.appendingPathComponent($0).path)
        }
        if !same {
            try? fm.removeItem(at: extensionFolder)
            try? fm.copyItem(at: source, to: extensionFolder)
        }
    }

    public func revealExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }

    public func openChromeExtensions() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? open.run()
    }
}

/// Lets a save swap the mailbox without rebuilding the engine.
struct DeferredMailSource: MailSource {
    let box: LockedValue<MailSource>
    func messages(from sender: String, since: Date) async throws -> [RawMail] {
        try await box.value.messages(from: sender, since: since)
    }
}
