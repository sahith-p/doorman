import Foundation

/// Everything the Settings window edits. Holds no secrets: passwords live in Apple Passwords or the
/// Keychain, and an account only says where to find its own.
public struct DoormanSettings: Codable, Equatable, Sendable {
    public var apps: [AppProfile]
    public var mail: MailSettings
    public var paused: Bool
    /// Experimental: let Doorman reach Claude's browser through macOS Accessibility.
    public var useAccessibility: Bool
    /// Set by `SettingsStore` on each save, to detect an old copy being put back.
    public var generation: Int
    /// Sites you haven't added can still be signed in to, using Apple Passwords. Always asks first.
    public var allowUnaddedSites: Bool
    /// Sites Doorman must never sign in to that way, separated by commas. A domain covers its subdomains.
    public var neverSites: String

    public init(apps: [AppProfile] = [], mail: MailSettings = MailSettings(), paused: Bool = false, useAccessibility: Bool = false) {
        self.apps = apps
        self.mail = mail
        self.paused = paused
        self.useAccessibility = useAccessibility
        self.generation = 0
        self.allowUnaddedSites = true
        self.neverSites = ""
    }

    public func isNeverSite(_ host: String) -> Bool {
        let bare = bareHost(host)
        return neverSites.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map { bareHost(String($0)) }.contains {
            !$0.isEmpty && (bare == $0 || bare.hasSuffix("." + $0))
        }
    }

    private enum CodingKeys: String, CodingKey { case apps, mail, paused, useAccessibility, generation, allowUnaddedSites, neverSites }

    /// Tolerant, so a settings file from an older version or an example file still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Apps saved before each app became one host don't decode, and just need adding again.
        apps = (try? c.decode([AppProfile].self, forKey: .apps)) ?? []
        mail = try c.decodeIfPresent(MailSettings.self, forKey: .mail) ?? MailSettings()
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        useAccessibility = try c.decodeIfPresent(Bool.self, forKey: .useAccessibility) ?? false
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        allowUnaddedSites = try c.decodeIfPresent(Bool.self, forKey: .allowUnaddedSites) ?? true
        neverSites = try c.decodeIfPresent(String.self, forKey: .neverSites) ?? ""
    }
}

/// One site an agent can sign in to, on one host. Production and staging are two apps.
public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Host, with a port if it has one: `app.example.com`, `localhost:8765`.
    public var host: String
    /// Shown on the prompt, so a real site stands out from a test one.
    public var isTest: Bool
    public var roles: [Role]
    public var accounts: [Account]

    public init(id: UUID = UUID(), name: String, host: String, isTest: Bool = false, roles: [Role] = [], accounts: [Account] = []) {
        self.id = id
        self.name = name
        self.host = host
        self.isTest = isTest
        self.roles = roles
        self.accounts = accounts
    }
}

public enum SignInMethod: String, Codable, CaseIterable, Sendable {
    case password, emailCode, emailLink

    public var label: String {
        switch self {
        case .password: return "Password"
        case .emailCode: return "Email code"
        case .emailLink: return "Email link"
        }
    }
}

/// Where a code comes from if the site asks for one. Never assumed: the engine only acts on what it
/// sees on the page.
public enum CodeSource: String, Codable, CaseIterable, Sendable {
    case authenticator, email, askMe, none

    public var label: String {
        switch self {
        case .authenticator: return "Authenticator"
        case .email: return "Email"
        case .askMe: return "Ask me"
        case .none: return "Stop and hand back"
        }
    }
}

public struct Role: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Path prefix on the host: `/admin`. The longest match wins, and `/` catches the rest.
    public var path: String
    public var signIn: SignInMethod
    public var codeIfAsked: CodeSource
    /// Who sends this role's code or link: addresses or domains, separated by commas. Mail from anyone
    /// else is ignored.
    public var mailSender: String
    /// Hosts a sign-in link may start on, besides the environment's own. For click-tracking domains.
    public var linkHosts: [String]
    /// Shown on the approval prompt, like "Reaches every customer org".
    public var warning: String

    public init(id: UUID = UUID(), name: String, path: String, signIn: SignInMethod = .password,
                codeIfAsked: CodeSource = .authenticator, mailSender: String = "", linkHosts: [String] = [], warning: String = "") {
        self.id = id
        self.name = name
        self.path = path
        self.signIn = signIn
        self.codeIfAsked = codeIfAsked
        self.mailSender = mailSender
        self.linkHosts = linkHosts
        self.warning = warning
    }

    /// Whether this role can need the mailbox.
    public var usesMail: Bool { signIn != .password || codeIfAsked == .email }

    public var mailSenders: [String] {
        mailSender.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public enum CredentialSource: Codable, Equatable, Sendable {
    /// No password, for email code and email link sign-ins.
    case none
    /// An Apple Passwords entry, found by site and login name.
    case applePasswords(site: String)
    /// Stored in Doorman's own Keychain item. Write-only in the UI.
    case stored
}

public enum ApprovalRule: String, Codable, CaseIterable, Sendable {
    case everyTime, noPopup

    public var label: String {
        switch self {
        case .everyTime: return "Ask me every time"
        case .noPopup: return "No popup"
        }
    }
}

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var roleID: UUID
    /// The login name typed into the site. Not a secret: it's shown on the approval prompt.
    public var login: String
    public var credential: CredentialSource
    public var approval: ApprovalRule

    public init(id: UUID = UUID(), name: String, roleID: UUID, login: String,
                credential: CredentialSource = .none, approval: ApprovalRule = .everyTime) {
        self.id = id
        self.name = name
        self.roleID = roleID
        self.login = login
        self.credential = credential
        self.approval = approval
    }
}

public enum MailProvider: String, Codable, CaseIterable, Sendable {
    case notConnected, gmail, imap
}

/// Mailbox settings. Tokens and passwords are in the Keychain, never here.
public struct MailSettings: Codable, Equatable, Sendable {
    public var provider: MailProvider
    public var address: String
    public var imapHost: String
    public var imapPort: Int
    public var gmailClientID: String

    public init(provider: MailProvider = .notConnected, address: String = "", imapHost: String = "imap.gmail.com", imapPort: Int = 993, gmailClientID: String = "") {
        self.provider = provider
        self.address = address
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.gmailClientID = gmailClientID
    }
}

/// `https://a.example.com:8443/x` or `A.example.com:8443` to `a.example.com:8443`.
public func normalizeHost(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
    if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
    return s
}

/// The host without a port: what Apple Passwords stores.
public func bareHost(_ raw: String) -> String {
    let host = normalizeHost(raw)
    return host.split(separator: ":").first.map(String.init) ?? host
}

public func hostKey(_ url: URL) -> String? {
    guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    if let port = url.port { return "\(host):\(port)" }
    return host
}

/// `/admin/` and `admin` to `/admin`. A blank path means the whole site.
public func normalizePath(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "/" }
    if !s.hasPrefix("/") { s = "/" + s }
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}
