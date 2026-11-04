import Foundation

public struct EngineTiming: Sendable {
    public var pagePoll: TimeInterval = 0.4
    /// Polls with no login form before the page counts as signed in. Long enough for a slow page.
    public var settlePolls: Int = 6
    /// How long the same form can stay up after a submit before the site counts as having refused.
    public var rejectAfter: TimeInterval = 6
    public var mailPoll: TimeInterval = 3
    public var mailWindow: TimeInterval = 90
    /// A code can land just before the page finishes submitting, so look slightly behind.
    public var mailLookback: TimeInterval = 20
    public var overall: TimeInterval = 240
    /// Polls a page can stay unreadable while it navigates.
    public var unreadablePolls: Int = 25
    public init() {}
}

public enum SettingsSnapshot: Sendable {
    case usable(DoormanSettings)
    case changedOutside
}

/// A hidden browser for `session_file` sign-ins.
public protocol SessionFileRunner: Sendable {
    func begin(address: URL) async throws -> (adapter: BrowserAdapter, tab: String)
    /// Saves the signed-in session and returns its path and expiry.
    func finish(adapter: BrowserAdapter, tab: String, host: String, label: String) async throws -> (path: String, expires: Date)
    func abort() async
}

/// One sign-in, start to finish. Agents only ever see the `SignInResult` this returns.
public final class SignInEngine: Sendable {
    private let settings: @Sendable () -> SettingsSnapshot
    private let approver: Approver
    private let passwords: PasswordSource
    private let mail: MailSource
    private let adapters: @Sendable () -> [BrowserAdapter]
    private let sessionFiles: SessionFileRunner?
    private let activity: ActivityLog
    private let timing: EngineTiming
    /// What's happening right now, in a few words, for the on-screen status. Never holds a secret.
    private let progress: @Sendable (String) -> Void
    private let lookups = LockedValue<[Date]>([])
    private static let lookupsPerMinute = 10

    private func allowLookup() -> Bool {
        let cutoff = Date().addingTimeInterval(-60)
        let recent = lookups.value.filter { $0 > cutoff }
        guard recent.count < Self.lookupsPerMinute else {
            lookups.value = recent
            return false
        }
        lookups.value = recent + [Date()]
        return true
    }

    public init(settings: @escaping @Sendable () -> SettingsSnapshot, approver: Approver, passwords: PasswordSource, mail: MailSource,
                adapters: @escaping @Sendable () -> [BrowserAdapter], sessionFiles: SessionFileRunner? = nil,
                activity: ActivityLog, timing: EngineTiming = EngineTiming(), progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.progress = progress
        self.settings = settings
        self.approver = approver
        self.passwords = passwords
        self.mail = mail
        self.adapters = adapters
        self.sessionFiles = sessionFiles
        self.activity = activity
        self.timing = timing
    }

    public func signIn(_ request: SignInRequest) async -> SignInResult {
        var log = ActivityEntry(agent: Self.agentName(request.agent), status: .failed)
        let result = await attempt(request, log: &log)
        log.status = result.status
        log.reason = result.reason
        activity.append(log)
        return result
    }

    private func attempt(_ request: SignInRequest, log: inout ActivityEntry) async -> SignInResult {
        let current: DoormanSettings
        switch settings() {
        case .changedOutside:
            return SignInResult(status: .needsYou, reason: Reason.settingsChanged,
                                message: "Doorman's settings changed outside the app. Open Doorman and review them.")
        case let .usable(value):
            current = value
        }
        if current.paused {
            return SignInResult(status: .paused, reason: Reason.paused, message: "Sign-ins are paused in Doorman.")
        }

        let resolved = Resolver.resolve(address: request.address, settings: current, roleName: request.role, accountName: request.account)
        log.host = URL(string: request.address).flatMap(hostKey) ?? ""
        let app: AppProfile, role: Role
        var candidates: [Account]
        var unaddedSite = false
        switch resolved {
        case .invalidAddress:
            return SignInResult(status: .failed, reason: Reason.invalidAddress, message: "That isn't a full http or https address.")
        case let .noApp(noAppHost):
            guard current.allowUnaddedSites, !current.isNeverSite(noAppHost) else {
                return SignInResult(status: .needsYou, reason: Reason.noApp, message: "Doorman isn't set up to sign in to that site.")
            }
            // Not added. Apple Passwords may still have a login for it: see below.
            role = Role(name: "", path: "/", signIn: .password, codeIfAsked: .authenticator)
            app = AppProfile(name: noAppHost, host: noAppHost, roles: [role])
            candidates = []
            unaddedSite = true
        case let .noRole(a):
            log.app = a.name
            return SignInResult(status: .needsYou, reason: Reason.noRole, message: "No role matches that path.", app: a.name)
        case let .roleNotFound(a, _):
            log.app = a.name
            return SignInResult(status: .needsYou, reason: Reason.noRole, message: "There's no role with that name.", app: a.name)
        case let .noAccount(a, r):
            log.app = a.name; log.role = r.name
            return SignInResult(status: .needsYou, reason: Reason.noAccount, message: "No account is set up for that role.", app: a.name, role: r.name)
        case let .accounts(a, r, list):
            app = a; role = r; candidates = list
        }
        log.app = app.name; log.role = role.name

        func done(_ status: SignInStatus, _ reason: String, _ message: String, account: Account? = nil) -> SignInResult {
            SignInResult(status: status, reason: reason, message: message, app: app.name, role: role.name, account: account?.name)
        }

        guard let url = URL(string: request.address.trimmingCharacters(in: .whitespacesAndNewlines)), let host = hostKey(url) else {
            return done(.failed, Reason.invalidAddress, "That isn't a full address.")
        }

        // Where the sign-in will happen. For a normal sign-in this is wherever the site is already open:
        // the agent doesn't name a browser, because it could lie and because it shouldn't have to.
        var adapter: BrowserAdapter
        var tab: TabInfo
        if request.sessionFile {
            guard sessionFiles != nil else { return done(.needsYou, Reason.noBrowser, "Session files aren't available in this build.") }
            adapter = PlaceholderAdapter()
            tab = TabInfo(id: "", url: request.address, title: "Hidden browser", active: true)
        } else {
            let connected = adapters()
            if connected.isEmpty {
                return done(.needsYou, Reason.noBrowser, "No browser is connected. See the Browsers page in Doorman.")
            }
            let hint = request.browser?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let usable = hint.isEmpty ? connected : connected.filter { $0.name.lowercased().contains(hint) }
            guard let found = await findTab(host: host, address: url, adapters: usable) else {
                return done(.needsYou, Reason.noWindow, "Doorman can't see \(host) in a connected browser. Open it first. In Claude's browser, the pane has to be showing.")
            }
            adapter = found.adapter
            tab = found.tab
        }
        log.via = request.sessionFile ? "Session file" : adapter.name

        // Nothing to do means nothing to approve: don't ask for a tap on a page that's already signed in.
        if !request.sessionFile, await looksSignedIn(adapter: adapter, tab: tab.id, host: host) {
            return done(.signedIn, Reason.alreadySignedIn, "This browser is already signed in here.")
        }

        if unaddedSite {
            guard Self.isSecure(url) else { return done(.needsYou, Reason.insecurePage, "The page isn't using https, so Doorman won't use a saved password on it.") }
            // Each answer tells an agent whether you have a login on that site, so it can't try hundreds.
            guard allowLookup() else { return done(.needsYou, Reason.tooManyLookups, "Too many lookups in a short time. Try again in a minute.") }
            let site = bareHost(host)
            let names: [String]
            do {
                names = try await passwords.loginNames(site: site)
            } catch PasswordSourceError.notConnected {
                return done(.needsYou, Reason.appleNotPaired, "Apple Passwords isn't connected. Connect it in Doorman.")
            } catch {
                return done(.needsYou, Reason.passwordUnavailable, "Doorman couldn't search Apple Passwords.")
            }
            guard !names.isEmpty else {
                return done(.needsYou, Reason.noApp, "Doorman has no app for that site, and Apple Passwords has no login for it.")
            }
            candidates = names.map { Account(name: $0, roleID: role.id, login: $0, credential: .applePasswords(site: site)) }
        }

        var account = candidates[0]
        // A site you haven't added always asks. There's no way to turn that off.
        if unaddedSite || candidates.count > 1 || Approval.asksFirst(account: account) {
            let ask = ApprovalRequest(
                app: app.name, appIsTest: app.isTest, role: role.name, roleWarning: unaddedSite ? "You haven't added this site" : role.warning,
                roleWasAsked: !(request.role ?? "").isEmpty, accounts: candidates.map { account in
                    var site: String?
                    if case let .applePasswords(value) = account.credential { site = normalizeHost(value) }
                    return AccountChoice(id: account.id, name: account.name, login: account.login, passwordSite: site)
                },
                host: host, via: log.via, windowTitle: Self.oneLine(tab.title, limit: 60), steps: unaddedSite ? "Password from Apple Passwords, plus a code if the site asks" : Self.describeSteps(role),
                agent: Self.agentName(request.agent), agentReason: Self.oneLine(request.reason, limit: 240))
            switch await approver.approve(ask) {
            case .denied:
                return done(.denied, Reason.userDenied, "You denied this sign-in.")
            case .timedOut:
                return done(.timeout, Reason.promptTimedOut, "Nobody answered the prompt in time.")
            case let .approved(id):
                guard let picked = candidates.first(where: { $0.id == id }) else {
                    return done(.denied, Reason.userDenied, "The prompt didn't pick an account from the list.")
                }
                account = picked
            }
        }
        log.account = account.name

        do {
            if request.sessionFile, let runner = sessionFiles {
                let started = try await runner.begin(address: url)
                adapter = started.adapter
                tab = TabInfo(id: started.tab, url: request.address, title: "", active: true)
                let outcome = try await run(adapter: adapter, tab: tab.id, url: url, host: host, role: role, account: account, app: app)
                guard outcome.status == .signedIn else {
                    await runner.abort()
                    return done(outcome.status, outcome.reason, outcome.message, account: account)
                }
                let saved = try await runner.finish(adapter: adapter, tab: tab.id, host: host, label: "\(app.name)-\(role.name)")
                var result = done(.signedIn, outcome.reason, "Saved a session file. It expires soon, and Doorman deletes it then.", account: account)
                result.sessionFile = saved.path
                result.sessionFileExpires = saved.expires
                return result
            }
            let outcome = try await run(adapter: adapter, tab: tab.id, url: url, host: host, role: role, account: account, app: app)
            return done(outcome.status, outcome.reason, outcome.message, account: account)
        } catch BrowserError.failed("page_moved") {
            // The page changed in the instant between looking and filling, and the page side refused.
            if request.sessionFile { await sessionFiles?.abort() }
            return done(.needsYou, Reason.wrongSite, "The page moved off \(host) as Doorman went to fill it, so nothing was typed.", account: account)
        } catch BrowserError.failed("page_not_https") {
            if request.sessionFile { await sessionFiles?.abort() }
            return done(.needsYou, Reason.insecurePage, "The page isn't using https, so Doorman won't fill it.", account: account)
        } catch {
            if request.sessionFile { await sessionFiles?.abort() }
            return done(.failed, Reason.browserError, "The browser stopped responding during sign-in.", account: account)
        }
    }

    /// Only true if the page stays free of any sign-in step for a little while. Anything else goes through
    /// the prompt as usual.
    private func looksSignedIn(adapter: BrowserAdapter, tab: String, host: String) async -> Bool {
        for _ in 0..<timing.settlePolls {
            guard let page = try? await adapter.inspect(tab: tab), let url = URL(string: page.url), hostKey(url) == host else { return false }
            if page.password || page.captcha || page.frameLogin || page.loginHints || Self.looksLikeLoginPath(url.path) { return false }
            try? await Task.sleep(nanoseconds: UInt64(timing.pagePoll * 1_000_000_000))
        }
        return true
    }

    private func findTab(host: String, address: URL, adapters: [BrowserAdapter]) async -> (adapter: BrowserAdapter, tab: TabInfo)? {
        var best: (adapter: BrowserAdapter, tab: TabInfo, score: Int)?
        for adapter in adapters {
            guard let tabs = try? await adapter.tabs() else { continue }
            for tab in tabs {
                guard let url = URL(string: tab.url), hostKey(url) == host else { continue }
                let score = (url.absoluteString == address.absoluteString ? 2 : 0) + (tab.active ? 1 : 0)
                if best == nil || score > best!.score { best = (adapter, tab, score) }
            }
        }
        return best.map { ($0.adapter, $0.tab) }
    }

    /// The agent writes its own name, and it goes in the prompt's title, so it can't be a sentence like
    /// "Your Mac needs you to approve this".
    static func agentName(_ raw: String) -> String {
        let allowed = raw.filter { $0.isLetter || $0.isNumber || "-_. ".contains($0) }.trimmingCharacters(in: .whitespaces)
        let name = String(allowed.prefix(32))
        return name.isEmpty ? "An agent" : name
    }

    /// Text from an agent or a page: one line, and short enough that it can't fill the prompt.
    static func oneLine(_ raw: String, limit: Int) -> String {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    public static func describeSteps(_ role: Role) -> String {
        switch role.signIn {
        case .emailCode:
            return role.mailSenders.isEmpty ? "Email code" : "Email code from \(role.mailSenders.joined(separator: " or "))"
        case .emailLink:
            return role.mailSenders.isEmpty ? "Email link" : "Email link from \(role.mailSenders.joined(separator: " or "))"
        case .password:
            switch role.codeIfAsked {
            case .none: return "Password"
            case .authenticator: return "Password, plus an authenticator code if asked"
            case .email: return "Password, plus an email code if asked"
            case .askMe: return "Password, and asks you if the site wants a code"
            }
        }
    }

    private struct Outcome {
        var status: SignInStatus
        var reason: String
        var message: String
    }

    /// Watches the page and acts only on what it sees, so 2FA is handled if a site asks and skipped if
    /// it doesn't. Each kind of step is tried once: a form that comes back means the site said no, and
    /// retrying a password can lock an account.
    private func run(adapter: BrowserAdapter, tab: String, url: URL, host: String, role: Role, account: Account, app: AppProfile) async throws -> Outcome {
        let deadline = Date().addingTimeInterval(timing.overall)
        var didUsername = false, didPassword = false, didCode = false, didLink = false
        var lastAction = Date.distantPast
        var urlAtAction = ""
        var quiet = 0
        var mailSince = Date().addingTimeInterval(-timing.mailLookback)
        let acted = { didUsername || didPassword || didCode || didLink }

        func pause() async { try? await Task.sleep(nanoseconds: UInt64(timing.pagePoll * 1_000_000_000)) }
        func settled() -> Bool { Date().timeIntervalSince(lastAction) > timing.rejectAfter }

        var unreadable = 0
        while Date() < deadline {
            // A page in the middle of navigating can't be read for a moment, which is normal right
            // after a submit. It only counts as broken if it stays that way.
            let page: PageState
            do {
                page = try await adapter.inspect(tab: tab)
                unreadable = 0
            } catch BrowserError.disconnected {
                throw BrowserError.disconnected
            } catch {
                unreadable += 1
                if unreadable > timing.unreadablePolls { throw error }
                await pause()
                continue
            }
            guard let pageURL = URL(string: page.url), let pageHost = hostKey(pageURL) else {
                return Outcome(status: .needsYou, reason: Reason.wrongSite, message: "Doorman can't read the page's address, so it stopped.")
            }
            if pageHost != host {
                // A sign-in link can pass through a click-tracking host on its way back. Nothing is
                // typed while it's there, and it has to land on the right host in the end.
                if didLink, role.linkHosts.map(normalizeHost).contains(pageHost) {
                    await pause()
                    continue
                }
                // Nothing typed from here on. The page left the host this account belongs to, which is
                // either single sign-on or something worse, and both are yours to look at.
                return Outcome(status: .needsYou, reason: Reason.wrongSite, message: "The page moved off \(host), so Doorman stopped.")
            }
            if !Self.isSecure(pageURL) {
                // A password sent over plain http can be read by anyone on the network.
                return Outcome(status: .needsYou, reason: Reason.insecurePage, message: "The page isn't using https, so Doorman won't fill it.")
            }
            if page.captcha {
                return Outcome(status: .needsYou, reason: Reason.captcha, message: "The page wants a CAPTCHA. That part is yours.")
            }

            if role.signIn == .emailLink, didUsername, !didLink {
                progress("Waiting for the sign-in link in your email")
                switch await waitForLink(role: role, app: app, since: mailSince) {
                case let .found(link):
                    try await adapter.navigate(tab: tab, url: link)
                    didLink = true
                    lastAction = Date()
                    quiet = 0
                    await pause()
                    continue
                case let .stop(outcome):
                    return outcome
                }
            }

            // A code box or a lone email box means nothing by itself. A signed-in page can have a promo
            // code or a newsletter field, and Doorman must not type a login or a code into those.
            let looksLikeSignIn = page.loginHints || Self.looksLikeLoginPath(pageURL.path)
            if page.code, acted() || looksLikeSignIn {
                quiet = 0
                if didCode {
                    if settled() { return Outcome(status: .failed, reason: Reason.codeRejected, message: "The site didn't accept the code.") }
                    await pause()
                    continue
                }
                let source: CodeSource = role.signIn == .emailCode ? .email : role.codeIfAsked
                let code: Secret
                switch source {
                case .none:
                    return Outcome(status: .needsYou, reason: Reason.codeRequested, message: "The site asked for a code and this role is set to hand back.")
                case .askMe:
                    guard let typed = await approver.askForCode(app: app.name, account: account.name), !typed.isEmpty else {
                        return Outcome(status: .needsYou, reason: Reason.codeRequested, message: "No code was entered.")
                    }
                    code = typed
                case .authenticator:
                    // No code saved for this login: you can read it off your phone and type it into Doorman.
                    if let value = try? await passwords.authenticatorCode(for: account, url: url) {
                        code = value
                    } else if let typed = await approver.askForCode(app: app.name, account: account.name), !typed.isEmpty {
                        code = typed
                    } else {
                        return Outcome(status: .needsYou, reason: Reason.codeRequested, message: "The site wants a code, and none was available.")
                    }
                case .email:
                    progress("Waiting for the code in your email")
                    switch await waitForCode(role: role, since: mailSince) {
                    case let .found(value):
                        code = value
                    case let .stop(outcome):
                        // No mailbox connected: you can read the code yourself and type it into Doorman.
                        guard outcome.reason == Reason.mailUnavailable,
                              let typed = await approver.askForCode(app: app.name, account: account.name), !typed.isEmpty else {
                            return outcome
                        }
                        code = typed
                    }
                }
                progress("Entering the code")
                try await adapter.fillCode(tab: tab, expectedHost: host, code: code, submit: true)
                didCode = true
                lastAction = Date()
                urlAtAction = page.url
                await pause()
                continue
            }

            if page.password {
                quiet = 0
                if didPassword {
                    if settled() { return Outcome(status: .failed, reason: Reason.passwordRejected, message: "The site didn't accept the password. Doorman won't retry it.") }
                    await pause()
                    continue
                }
                let credential: Credential
                do {
                    credential = try await passwords.credential(for: account, host: host)
                } catch PasswordSourceError.notConnected {
                    return Outcome(status: .needsYou, reason: Reason.appleNotPaired, message: "Apple Passwords isn't connected. Connect it in Doorman.")
                } catch {
                    return Outcome(status: .needsYou, reason: Reason.passwordUnavailable, message: "Doorman couldn't get the password for this account.")
                }
                progress("Entering your password")
                try await adapter.fillLogin(tab: tab, expectedHost: host, username: page.username ? credential.username : nil, password: credential.password, submit: true)
                didPassword = true
                lastAction = Date()
                urlAtAction = page.url
                // A code the site emails after the password can only be newer than this.
                mailSince = Date().addingTimeInterval(-timing.mailLookback)
                await pause()
                continue
            }

            if page.username, acted() || looksLikeSignIn {
                quiet = 0
                if didUsername {
                    if settled() { return Outcome(status: .failed, reason: Reason.loginRejected, message: "The site didn't move past the login name.") }
                    await pause()
                    continue
                }
                progress("Entering your login")
                try await adapter.fillLogin(tab: tab, expectedHost: host, username: account.login, password: nil, submit: true)
                didUsername = true
                lastAction = Date()
                urlAtAction = page.url
                mailSince = Date().addingTimeInterval(-timing.mailLookback)
                await pause()
                continue
            }

            // No form on the page.
            quiet += 1
            if role.signIn == .emailCode, didUsername, !didCode {
                if settled() { return Outcome(status: .needsYou, reason: Reason.noForm, message: "The site didn't show a code box after the login name.") }
                await pause()
                continue
            }
            if page.frameLogin {
                return Outcome(status: .needsYou, reason: Reason.noForm, message: "The sign-in form is inside an embedded frame, which Doorman won't fill.")
            }
            if quiet >= timing.settlePolls {
                if !acted() {
                    if looksLikeSignIn {
                        return Outcome(status: .needsYou, reason: Reason.noForm, message: "This looks like a sign-in page, but Doorman doesn't recognise its form.")
                    }
                    return Outcome(status: .signedIn, reason: Reason.alreadySignedIn, message: "This browser is already signed in here.")
                }
                if looksLikeSignIn {
                    if settled() {
                        return Outcome(status: .needsYou, reason: Reason.noForm, message: "The page still looks like a sign-in page, but has no form Doorman recognises.")
                    }
                } else if page.url != urlAtAction || settled() {
                    // Don't call it signed in on a pause alone: the address has to have moved on, or
                    // the page has to have stayed free of any sign-in step for a while.
                    return Outcome(status: .signedIn, reason: "", message: "Signed in.")
                }
            }
            await pause()
        }
        return Outcome(status: .timeout, reason: Reason.timedOut, message: "The sign-in took too long.")
    }

    /// https, or a page on this Mac.
    static func isSecure(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func looksLikeLoginPath(_ path: String) -> Bool {
        path.lowercased().range(of: #"(^|/)(log-?in|sign-?in|auth|verify|2fa|mfa|otp)(/|$)"#, options: .regularExpression) != nil
    }

    private enum MailWait<Value> {
        case found(Value)
        case stop(Outcome)
    }

    private func waitForCode(role: Role, since: Date) async -> MailWait<Secret> {
        await waitForMail(role: role, since: since) { mail in MailExtract.code(in: mail).map { Secret($0) } }
    }

    private func waitForLink(role: Role, app: AppProfile, since: Date) async -> MailWait<URL> {
        await waitForMail(role: role, since: since) { mail in
            MailExtract.link(in: mail, allowedHosts: [app.host] + role.linkHosts)
        }
    }

    private func waitForMail<Value>(role: Role, since: Date, extract: (ParsedMail) -> Value?) async -> MailWait<Value> {
        let senders = role.mailSenders
        guard !senders.isEmpty else {
            return .stop(Outcome(status: .needsYou, reason: Reason.mailUnavailable, message: "This role has no email sender set."))
        }
        let until = Date().addingTimeInterval(timing.mailWindow)
        var lastFailure = false, sawUnverified = false, sawNothingUsable = false
        while Date() < until {
            do {
                for sender in senders {
                    for raw in try await mail.messages(from: sender, since: since) {
                        let parsed = MailParser.parse(raw.rfc822)
                        guard senders.contains(where: { MailExtract.fromMatches(parsed, expected: $0) }) else { continue }
                        if let date = parsed.date ?? Optional(raw.received), date < since { continue }
                        guard MailExtract.verified(parsed) else {
                            sawUnverified = true
                            continue
                        }
                        if let value = extract(parsed) { return .found(value) }
                        sawNothingUsable = true
                    }
                }
                lastFailure = false
            } catch MailSourceError.notConnected {
                return .stop(Outcome(status: .needsYou, reason: Reason.mailUnavailable, message: "No mailbox is connected. Connect one in Doorman."))
            } catch {
                lastFailure = true
            }
            try? await Task.sleep(nanoseconds: UInt64(timing.mailPoll * 1_000_000_000))
        }
        // Say which of these it was, so a wrong setting can be told apart from a slow email.
        if lastFailure {
            return .stop(Outcome(status: .failed, reason: Reason.mailNotFound, message: "Doorman couldn't read the mailbox."))
        }
        if sawUnverified {
            return .stop(Outcome(status: .failed, reason: Reason.mailNotVerified, message: "An email came from that sender, but your mail server couldn't confirm it was really them, so Doorman didn't use it."))
        }
        if sawNothingUsable {
            return .stop(Outcome(status: .failed, reason: Reason.mailNoCode, message: "An email came from that sender, but Doorman found nothing in it to use."))
        }
        return .stop(Outcome(status: .failed, reason: Reason.mailNotFound, message: "No email from \(senders.joined(separator: " or ")) arrived in time."))
    }
}

/// Stands in until the hidden browser starts, which only happens after approval.
private struct PlaceholderAdapter: BrowserAdapter {
    var name = "Hidden browser"
    func tabs() async throws -> [TabInfo] { [] }
    func inspect(tab: String) async throws -> PageState { throw BrowserError.disconnected }
    func fillLogin(tab: String, expectedHost: String, username: String?, password: Secret?, submit: Bool) async throws { throw BrowserError.disconnected }
    func fillCode(tab: String, expectedHost: String, code: Secret, submit: Bool) async throws { throw BrowserError.disconnected }
    func navigate(tab: String, url: URL) async throws { throw BrowserError.disconnected }
}
