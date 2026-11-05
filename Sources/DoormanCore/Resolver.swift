import Foundation

/// What an address means, given the settings.
public enum Resolution: Equatable, Sendable {
    case invalidAddress
    case noApp(host: String)
    case noRole(app: AppProfile)
    case roleNotFound(app: AppProfile, asked: String)
    case noAccount(app: AppProfile, role: Role)
    case accounts(app: AppProfile, role: Role, accounts: [Account])
}

public enum Resolver {
    /// The host picks the app. The path picks the role, unless the agent asked for one by name, which the
    /// prompt shows. An agent can't choose the app: only the address can.
    public static func resolve(address: String, settings: DoormanSettings, roleName: String? = nil, accountName: String? = nil) -> Resolution {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let key = hostKey(url) else { return .invalidAddress }

        guard let app = settings.apps.first(where: { normalizeHost($0.host) == key }) else { return .noApp(host: key) }

        let role: Role
        if let asked = roleName?.trimmingCharacters(in: .whitespaces), !asked.isEmpty {
            guard let found = app.roles.first(where: { $0.name.caseInsensitiveCompare(asked) == .orderedSame }) else {
                return .roleNotFound(app: app, asked: asked)
            }
            role = found
        } else {
            guard let found = longestPathMatch(roles: app.roles, path: url.path) else { return .noRole(app: app) }
            role = found
        }

        var matched = app.accounts.filter { $0.roleID == role.id }
        if let asked = accountName?.trimmingCharacters(in: .whitespaces), !asked.isEmpty {
            matched = matched.filter { $0.name.caseInsensitiveCompare(asked) == .orderedSame }
        }
        if matched.isEmpty { return .noAccount(app: app, role: role) }
        return .accounts(app: app, role: role, accounts: matched)
    }

    static func longestPathMatch(roles: [Role], path: String) -> Role? {
        let target = path.isEmpty ? "/" : path
        return roles
            .map { (role: $0, prefix: normalizePath($0.path)) }
            .filter { $0.prefix == "/" || target == $0.prefix || target.hasPrefix($0.prefix + "/") }
            .max(by: { $0.prefix.count < $1.prefix.count })?
            .role
    }

    /// The Test an address line in Settings.
    public static func describe(_ resolution: Resolution) -> String {
        switch resolution {
        case .invalidAddress:
            return "Enter a full address, like https://app.example.com/login"
        case .noApp:
            return "No app has that host, so Doorman won't sign in there."
        case let .noRole(app):
            return "\(app.name), but no role matches that path. The agent gets needs_you."
        case let .roleNotFound(app, asked):
            return "\(app.name), but there's no role called \(asked)."
        case let .noAccount(app, role):
            return "\(app.name), \(role.name): no account set up. The agent gets needs_you."
        case let .accounts(app, role, accounts):
            let head = "\(app.name), \(role.name): "
            if accounts.count > 1 { return head + "\(accounts.count) accounts match, so the prompt asks you which." }
            let account = accounts[0]
            let rule = Approval.asksFirst(account: account) ? "Asks you first." : "No popup."
            return head + "\(account.name). \(rule)"
        }
    }
}

public enum Approval {
    /// Whether an Apple Passwords site belongs with this host: the same name, or one inside the other.
    /// A mismatch still works, because someone may share a login on purpose, but the prompt says so.
    public static func siteMatches(site: String, host: String) -> Bool {
        let a = bareHost(site), b = bareHost(host)
        guard !a.isEmpty else { return false }
        if a == b { return true }
        let parent = a.hasSuffix("." + b) ? b : b.hasSuffix("." + a) ? a : nil
        guard let parent, parent.contains("."), !sharedSuffixes.contains(parent) else { return false }
        return true
    }

    /// Domains where each subdomain belongs to a different person, so one isn't "the same site" as the
    /// next. The common ones, not the whole public suffix list.
    private static let sharedSuffixes: Set<String> = [
        "vercel.app", "github.io", "gitlab.io", "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
        "herokuapp.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "onrender.com", "fly.dev", "railway.app",
        "ngrok.io", "ngrok.app", "ngrok-free.app", "replit.app", "surge.sh", "wixsite.com", "webflow.io", "blogspot.com",
        "co.uk", "org.uk", "ac.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "co.in", "co.kr", "com.br", "com.mx", "com.cn",
    ]

    /// Every account asks first unless you turned that off for it. Turning it off is a settings change,
    /// so it takes Touch ID, and an agent can't do it.
    public static func asksFirst(account: Account) -> Bool { account.approval == .everyTime }
}

/// Problems that stop a save. Plain language, because they're shown in Settings.
public enum SettingsValidator {
    public static func problems(_ settings: DoormanSettings) -> [String] {
        var out: [String] = []
        var seenHosts: [String: String] = [:]
        for app in settings.apps {
            let title = app.name.isEmpty ? "An app" : app.name
            if app.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Every app needs a name.") }
            let host = normalizeHost(app.host)
            if host.isEmpty { out.append("\(title) needs a host.") }
            if let other = seenHosts[host], !host.isEmpty {
                out.append("\(host) is in both \(other) and \(title). A host can only belong to one app.")
            }
            seenHosts[host] = title
            for role in app.roles where role.usesMail && role.mailSenders.isEmpty {
                out.append("\(title), \(role.name): enter who sends the email, or Doorman can't tell the real one apart.")
            }
            for account in app.accounts {
                guard let role = app.roles.first(where: { $0.id == account.roleID }) else {
                    out.append("\(title), \(account.name): pick a role.")
                    continue
                }
                if account.login.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append("\(title), \(account.name): enter the login name.")
                }
                if role.signIn == .password, account.credential == .none {
                    out.append("\(title), \(account.name): choose where the password comes from.")
                }
            }
        }
        return out
    }
}
