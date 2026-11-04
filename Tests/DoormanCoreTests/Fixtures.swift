import Foundation
@testable import DoormanCore

/// Acme's real shape: production and staging are two apps, with the same paths on different hosts.
func acmeSettings() -> DoormanSettings {
    func roles() -> (Role, Role, Role) {
        (Role(name: "Superadmin", path: "/admin", signIn: .emailCode, mailSender: "no-reply@example.com, login@mail.example.org", warning: "Reaches every customer org"),
         Role(name: "Technician", path: "/technician", signIn: .password, codeIfAsked: .authenticator),
         Role(name: "Admin", path: "/", signIn: .password, codeIfAsked: .authenticator))
    }
    let (ps, pt, pa) = roles()
    let (ss, st, sa) = roles()
    return DoormanSettings(apps: [
        AppProfile(name: "Acme Production", host: "app.example.com", roles: [ps, pt, pa], accounts: [
            Account(name: "Prod superadmin", roleID: ps.id, login: "me@example.com"),
            Account(name: "Prod admin", roleID: pa.id, login: "a@example.com", credential: .applePasswords(site: "app.example.com")),
        ]),
        AppProfile(name: "Acme Staging", host: "staging.example.net", isTest: true, roles: [ss, st, sa], accounts: [
            Account(name: "Staging superadmin", roleID: ss.id, login: "me@example.com"),
            Account(name: "Test tech 66", roleID: st.id, login: "t66@example.com", credential: .stored, approval: .noPopup),
            Account(name: "Test tech 65", roleID: st.id, login: "t65@example.com", credential: .stored, approval: .noPopup),
            Account(name: "Staging admin", roleID: sa.id, login: "a@example.com", credential: .stored, approval: .noPopup),
        ]),
    ])
}

struct FakeApprover: Approver {
    var decision: ApprovalDecision?
    var log = Box<[ApprovalRequest]>([])
    var typedCode: String? = nil
    func approve(_ request: ApprovalRequest) async -> ApprovalDecision {
        log.value.append(request)
        return decision ?? .approved(accountID: request.accounts[0].id)
    }
    func askForCode(app: String, account: String) async -> Secret? { typedCode.map { Secret($0) } }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

struct FakePasswords: PasswordSource {
    var password = "hunter2-demo"
    var code: String? = "424242"
    var error: PasswordSourceError? = nil
    func credential(for account: Account, host: String) async throws -> Credential {
        if let error { throw error }
        return Credential(username: account.login, password: Secret(password))
    }
    func authenticatorCode(for account: Account, url: URL) async throws -> Secret? { code.map { Secret($0) } }
}

struct FakeMail: MailSource {
    var mails = Box<[RawMail]>([])
    var error: MailSourceError? = nil
    func messages(from sender: String, since: Date) async throws -> [RawMail] {
        if let error { throw error }
        return mails.value
    }
    func deliver(_ text: String) {
        mails.value.insert(RawMail(received: Date(), rfc822: Data(text.utf8)), at: 0)
    }
}

/// A scripted site: `pages` is what the browser shows in order, moving on after each fill.
final class FakeBrowser: BrowserAdapter, @unchecked Sendable {
    let name = "Fake"
    var tabURL: String
    var title = "Sign in"
    var pages: [PageState]
    var fills: [String] = []
    var filledPasswords: [String] = []
    var filledCodes: [String] = []
    var navigations: [URL] = []
    var onFill: ((FakeBrowser) -> Void)?
    init(url: String, pages: [PageState]) {
        self.tabURL = url
        self.pages = pages
    }
    func tabs() async throws -> [TabInfo] { [TabInfo(id: "1", url: tabURL, title: title, active: true)] }
    var inspectFailures = 0
    var inspectError: BrowserError = .failed("Frame with ID 0 was removed")
    var fillError: BrowserError?
    func inspect(tab: String) async throws -> PageState {
        if inspectFailures > 0 {
            inspectFailures -= 1
            throw inspectError
        }
        return pages[0]
    }
    private func advance() {
        if pages.count > 1 { pages.removeFirst() }
        onFill?(self)
    }
    func fillLogin(tab: String, expectedHost: String, username: String?, password: Secret?, submit: Bool) async throws {
        if let fillError { throw fillError }
        fills.append("login:\(username ?? "-"):\(password == nil ? "nopw" : "pw")")
        if let password { filledPasswords.append(password.reveal()) }
        advance()
    }
    func fillCode(tab: String, expectedHost: String, code: Secret, submit: Bool) async throws {
        fills.append("code")
        filledCodes.append(code.reveal())
        advance()
    }
    func navigate(tab: String, url: URL) async throws {
        navigations.append(url)
        advance()
    }
}

func fastTiming() -> EngineTiming {
    var t = EngineTiming()
    t.pagePoll = 0.005
    t.settlePolls = 3
    t.rejectAfter = 0.05
    t.mailPoll = 0.01
    t.mailWindow = 0.2
    t.mailLookback = 60
    t.overall = 3
    t.unreadablePolls = 5
    return t
}

func demoMail(from: String, subject: String, body: String, date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    let domain = from.split(separator: "@").last.map(String.init) ?? ""
    return "From: Demo <\(from)>\r\nAuthentication-Results: mx.test; dmarc=pass header.from=\(domain)\r\nSubject: \(subject)\r\nDate: \(f.string(from: date))\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
}
