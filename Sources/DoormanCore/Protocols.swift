import Foundation

public enum SignInStatus: String, Codable, Sendable {
    case signedIn = "signed_in"
    case denied
    case timeout
    case needsYou = "needs_you"
    case failed
    case paused
    case pending
}

/// Everything an agent ever gets back. Codable on purpose, with no field that could hold a secret:
/// `reason` is one of the fixed codes in `Reason`, and `message` is written by Doorman.
public struct SignInResult: Codable, Equatable, Sendable {
    public var status: SignInStatus
    public var reason: String
    public var message: String
    public var requestID: String?
    public var app: String?
    public var role: String?
    public var account: String?
    /// Path to a Playwright storage state file, for `session_file` sign-ins.
    public var sessionFile: String?
    public var sessionFileExpires: Date?

    public init(status: SignInStatus, reason: String = "", message: String = "", requestID: String? = nil, app: String? = nil,
                role: String? = nil, account: String? = nil, sessionFile: String? = nil, sessionFileExpires: Date? = nil) {
        self.status = status
        self.reason = reason
        self.message = message
        self.requestID = requestID
        self.app = app
        self.role = role
        self.account = account
        self.sessionFile = sessionFile
        self.sessionFileExpires = sessionFileExpires
    }
}

public enum Reason {
    public static let alreadySignedIn = "already_signed_in"
    public static let invalidAddress = "invalid_address"
    public static let noApp = "no_app"
    public static let tooManyLookups = "too_many_lookups"
    public static let noRole = "no_role"
    public static let noAccount = "no_account"
    public static let noWindow = "no_window"
    public static let noBrowser = "no_browser"
    public static let userDenied = "user_denied"
    public static let promptTimedOut = "prompt_timed_out"
    public static let paused = "paused"
    public static let settingsChanged = "settings_changed_outside"
    public static let wrongSite = "left_expected_site"
    public static let insecurePage = "page_not_https"
    public static let captcha = "captcha"
    public static let codeRequested = "code_requested"
    public static let passwordUnavailable = "password_unavailable"
    public static let appleNotPaired = "apple_passwords_not_connected"
    public static let passwordRejected = "password_rejected"
    public static let codeRejected = "code_rejected"
    public static let loginRejected = "login_rejected"
    public static let mailUnavailable = "mailbox_not_connected"
    public static let mailNotFound = "mail_not_found"
    public static let mailNotVerified = "mail_not_verified"
    public static let mailNoCode = "mail_had_no_code"
    public static let linkNotAllowed = "link_not_allowed"
    public static let timedOut = "timed_out"
    public static let browserError = "browser_error"
    public static let noForm = "no_login_form"
}

public struct SignInRequest: Sendable {
    public var address: String
    public var role: String?
    public var account: String?
    public var reason: String
    public var agent: String
    public var sessionFile: Bool
    /// Optional: part of a browser's name, when the site is open in more than one. It only narrows where
    /// to look, and the prompt still shows which browser it is.
    public var browser: String?

    public init(address: String, role: String? = nil, account: String? = nil, reason: String = "", agent: String = "agent", sessionFile: Bool = false, browser: String? = nil) {
        self.browser = browser
        self.address = address
        self.role = role
        self.account = account
        self.reason = reason
        self.agent = agent
        self.sessionFile = sessionFile
    }
}

public struct ApprovalRequest: Sendable, Identifiable {
    public var id = UUID()
    public var app: String
    public var appIsTest: Bool
    public var role: String
    public var roleWarning: String
    public var roleWasAsked: Bool
    public var accounts: [AccountChoice]
    public var host: String
    public var via: String
    public var windowTitle: String
    public var steps: String
    public var agent: String
    /// Written by the agent. The prompt labels it as not verified.
    public var agentReason: String

    public init(app: String, appIsTest: Bool, role: String, roleWarning: String, roleWasAsked: Bool,
                accounts: [AccountChoice], host: String, via: String, windowTitle: String, steps: String, agent: String, agentReason: String) {
        self.app = app
        self.appIsTest = appIsTest
        self.role = role
        self.roleWarning = roleWarning
        self.roleWasAsked = roleWasAsked
        self.accounts = accounts
        self.host = host
        self.via = via
        self.windowTitle = windowTitle
        self.steps = steps
        self.agent = agent
        self.agentReason = agentReason
    }
}

public struct AccountChoice: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var login: String
    /// The Apple Passwords site this account reads from, shown so a mismatch can't go unnoticed.
    public var passwordSite: String?
    public init(id: UUID, name: String, login: String, passwordSite: String? = nil) {
        self.id = id
        self.name = name
        self.login = login
        self.passwordSite = passwordSite
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved(accountID: UUID)
    case denied
    case timedOut
}

/// The prompt and the tap. In the app it's the approval window plus Touch ID.
public protocol Approver: Sendable {
    func approve(_ request: ApprovalRequest) async -> ApprovalDecision
    /// "Ask me" codes: you read the code off your phone and type it into Doorman, not into the agent.
    func askForCode(app: String, account: String) async -> Secret?
}

public protocol PasswordSource: Sendable {
    /// Login names saved for a site, for sites you haven't added. Reads no password.
    func loginNames(site: String) async throws -> [String]
    func credential(for account: Account, host: String) async throws -> Credential
    /// A current authenticator code from Apple Passwords, if the entry has one.
    func authenticatorCode(for account: Account, url: URL) async throws -> Secret?
}

extension PasswordSource {
    public func loginNames(site: String) async throws -> [String] { [] }
}

public enum PasswordSourceError: Error, Sendable, Equatable {
    case notConnected
    case notFound
    case unavailable(String)
}

public struct RawMail: Sendable {
    public var received: Date
    public var rfc822: Data
    public init(received: Date, rfc822: Data) {
        self.received = received
        self.rfc822 = rfc822
    }
}

public protocol MailSource: Sendable {
    /// Newest first. Implementations ask the server for this sender and time window only.
    func messages(from sender: String, since: Date) async throws -> [RawMail]
}

public enum MailSourceError: Error, Sendable, Equatable {
    case notConnected
    case failed(String)
}

public struct TabInfo: Sendable, Equatable {
    public var id: String
    public var url: String
    public var title: String
    public var active: Bool
    public init(id: String, url: String, title: String, active: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.active = active
    }
}

/// What's on the page right now, as seen by the browser side. `url` comes from the browser itself.
public struct PageState: Codable, Sendable, Equatable {
    public var url: String
    public var username: Bool
    public var password: Bool
    public var code: Bool
    public var captcha: Bool
    /// The page's title, headings or buttons read like a sign-in step.
    public var loginHints: Bool
    /// A sign-in form in an embedded frame, which Doorman won't fill.
    public var frameLogin: Bool

    public init(url: String, username: Bool = false, password: Bool = false, code: Bool = false, captcha: Bool = false, loginHints: Bool = false, frameLogin: Bool = false) {
        self.url = url
        self.username = username
        self.password = password
        self.code = code
        self.captcha = captcha
        self.loginHints = loginHints
        self.frameLogin = frameLogin
    }
}

public enum BrowserError: Error, Sendable, Equatable {
    case disconnected
    case failed(String)
}

/// One way of reaching a browser. `tabs()` is how the engine finds where an agent is working, so an
/// agent never has to say which browser it's in.
public protocol BrowserAdapter: Sendable {
    var name: String { get }
    func tabs() async throws -> [TabInfo]
    func inspect(tab: String) async throws -> PageState
    /// `expectedHost` is checked inside the page at the moment of filling: a page can navigate between
    /// being looked at and being filled.
    func fillLogin(tab: String, expectedHost: String, username: String?, password: Secret?, submit: Bool) async throws
    func fillCode(tab: String, expectedHost: String, code: Secret, submit: Bool) async throws
    func navigate(tab: String, url: URL) async throws
}

/// Passwords held in memory, for tests and the e2e. The app uses Apple Passwords and the Keychain.
public struct StaticPasswordSource: PasswordSource {
    private let password: Secret
    private let code: Secret?
    public init(password: String, code: String? = nil) {
        self.password = Secret(password)
        self.code = code.map { Secret($0) }
    }
    public func credential(for account: Account, host: String) async throws -> Credential {
        Credential(username: account.login, password: password)
    }
    public func authenticatorCode(for account: Account, url: URL) async throws -> Secret? { code }
}
