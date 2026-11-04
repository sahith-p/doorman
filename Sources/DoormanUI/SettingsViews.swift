import SwiftUI
import AppKit
import DoormanCore

public struct SettingsRoot: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    public var body: some View {
        // A plain split rather than NavigationSplitView: the sidebar then draws the same everywhere,
        // including in the screenshot tool, which is how this UI gets reviewed.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                if model.changedOutside { ChangedOutsideBanner() }
                if let error = model.loadError {
                    Text(error).font(.callout).foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                detail
                if model.isDirty || !model.saveMessage.isEmpty { SaveBar() }
            }
            .frame(minWidth: 620, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        }
        // In the Dock while you're editing, and only in the menu bar the rest of the time.
        .onAppear {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(title: "Get started", icon: "sparkles", item: .start)
                    SidebarHeading(text: "Apps").padding(.top, 10)
                    ForEach(model.draft.apps) { app in
                        SidebarRow(title: app.name.isEmpty ? "Untitled" : app.name, icon: "app.dashed", item: .app(app.id))
                    }
                    Button { model.addApp() } label: {
                        Label("Add app", systemImage: "plus").foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    SidebarHeading(text: "Doorman").padding(.top, 10)
                    SidebarRow(title: "Activity", icon: "clock", item: .activity)
                    SidebarRow(title: "Apple Passwords", icon: "key", item: .apple)
                    SidebarRow(title: "Email", icon: "envelope", item: .email)
                    SidebarRow(title: "Browsers", icon: "safari", item: .browsers)
                }
                .padding(10)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Import…") { model.importSettings() }
                Button("Export…") { model.exportSettings() }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(10)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case let .app(id):
            if let i = model.draft.apps.firstIndex(where: { $0.id == id }) {
                AppDetailView(app: $model.draft.apps[i])
            } else {
                EmptyAppsView()
            }
        case .start: GetStartedView()
        case .activity: ActivityView()
        case .email: EmailView()
        case .browsers: BrowsersView()
        case .apple: ApplePasswordsView()
        case .none: GetStartedView()
        }
    }
}

struct SidebarHeading: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
    }
}

struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let icon: String
    let item: SidebarItem

    var body: some View {
        Button { model.selection = item } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(title).lineLimit(1)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(model.selection == item ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ChangedOutsideBanner: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("These settings were changed outside Doorman").fontWeight(.medium)
                Text("Sign-ins are stopped until you review them. Look through what's below, then save with Touch ID to accept it, or start over.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Start over") { model.discardAndStartEmpty() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

struct SaveBar: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ForEach(model.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            HStack {
                Text(model.isDirty ? "Unsaved changes" : model.saveMessage).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.isDirty {
                    Button("Discard") { model.revert() }
                    Button {
                        model.save()
                    } label: {
                        Label("Save with Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.problems.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }
}

struct EmptyAppsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.viewfinder").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("That app is gone").font(.title2)
            HStack {
                Button("Add app") { model.addApp() }.buttonStyle(.borderedProminent)
                Button("Import…") { model.importSettings() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The first thing you see: what's connected, and what to do next.
public struct GetStartedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    public init() {}

    private var appleDone: Bool { model.appleState == .paired }
    private var mailDone: Bool { model.saved.mail.provider != .notConnected }
    private var browserDone: Bool { model.browserCount > 0 || model.saved.useAccessibility }

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let agents sign in without seeing a password").font(.title2.weight(.semibold))
                    Text("An agent asks Doorman to sign in. You approve it with Touch ID. Doorman fills the page, and the agent never sees the password or code.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Set up") {
                SetupRow(done: appleDone, title: "Connect Apple Passwords", detail: "Lets Doorman use your saved logins. You type a 6-digit code from macOS once.", action: "Open") { model.selection = .apple }
                SetupRow(done: browserDone, title: "Connect a browser", detail: "A small extension lets Doorman fill pages in Chrome, Brave or Edge.", action: "Open") { model.selection = .browsers }
                SetupRow(done: mailDone, title: "Connect your email (optional)", detail: "For sites that email a code or a sign-in link. Read-only, and only during a sign-in you approved.", action: "Open") { model.selection = .email }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude Code").font(.callout.weight(.medium))
                    HStack {
                        Text(model.claudeCodeCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            model.copy(model.claudeCodeCommand)
                            copied = true
                        }
                    }
                    Text("Other agents: add an MCP server with this as its command.").font(.callout.weight(.medium)).padding(.top, 4)
                    Text(model.mcpPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Text("Give an agent access")
            } footer: {
                Text("Start a new agent session afterward, then ask it to sign in to a page you have open.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Doorman can use Apple Passwords for any site, so you don't have to add anything. Add an app when a site needs more: different logins by path, a code by email, or a sign-in with no password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add app") { model.addApp() }
                    Button("Import…") { model.importSettings() }
                    if model.demoSiteRunning { Button("Try the demo site") { model.addDemoApp() } }
                }
            } header: {
                Text("Sites")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.checkDemoSite() }
    }
}

struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String
    let action: String
    let run: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(done ? "Change" : action, action: run)
        }
        .padding(.vertical, 2)
    }
}

struct AppDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var app: AppProfile
    @State private var testAddress = ""

    var body: some View {
        Form {
            Section {
                HStack(alignment: .bottom, spacing: 10) {
                    Captioned("Name") { TextField("Name", text: $app.name, prompt: Text("Acme Staging")) }
                        .frame(width: 180)
                    Captioned("Host") { TextField("Host", text: $app.host, prompt: Text("app.example.com")) }
                    Toggle("Test site", isOn: $app.isTest)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .padding(.bottom, 4)
                    Button(role: .destructive) { model.removeApp(app.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this app")
                        .padding(.bottom, 4)
                }
                .textFieldStyle(.roundedBorder)
            } footer: {
                Text("One app per host. Production and staging are two apps. An agent can't pick one: the page's real address does.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Address", text: $testAddress, prompt: Text("https://app.example.com/login"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                if !testAddress.isEmpty {
                    Text(model.testAddress(testAddress, in: app)).font(.callout)
                }
            } header: {
                Text("Test an address")
            } footer: {
                Text("Paste an address to see which login it picks, before any agent uses it.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($app.roles) { $role in
                    RoleRow(role: $role, captions: role.id == app.roles.first?.id) { app.roles.removeAll { $0.id == role.id } }
                }
                Button { app.roles.append(Role(name: "", path: "/")) } label: { Label("Add role", systemImage: "plus") }
                    .buttonStyle(.borderless)
            } header: {
                Text("Roles")
            } footer: {
                Text("The path decides the role, and the longest match wins. Use / to catch everything else.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($app.accounts) { $account in
                    AccountRow(account: $account, appHost: app.host, isTestApp: app.isTest, roles: app.roles, captions: account.id == app.accounts.first?.id) {
                        app.accounts.removeAll { $0.id == account.id }
                    }
                }
                Button {
                    if let r = app.roles.first {
                        app.accounts.append(Account(name: "", roleID: r.id, login: ""))
                    }
                } label: { Label("Add account", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(app.roles.isEmpty)
            } header: {
                Text("Accounts")
            }
        }
        .formStyle(.grouped)
    }
}

/// A control with a small caption over it. Form rows would otherwise lay labels out in their own way,
/// which clips rows that hold several controls.
struct Captioned<Content: View>: View {
    let caption: String
    let show: Bool
    @ViewBuilder let content: Content
    init(_ caption: String, show: Bool = true, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.show = show
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if show { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            content.labelsHidden()
        }
    }
}

struct RoleRow: View {
    @Binding var role: Role
    let captions: Bool
    let onDelete: () -> Void
    @State private var addingWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Captioned("Name", show: captions) { TextField("Name", text: $role.name, prompt: Text("Admin")) }
                    .frame(width: 120)
                Captioned("Path", show: captions) { TextField("Path", text: $role.path, prompt: Text("/admin")) }
                    .frame(width: 110)
                Captioned("Signs in with", show: captions) {
                    Picker("Signs in with", selection: $role.signIn) {
                        ForEach(SignInMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                if role.signIn != .emailCode {
                    Captioned("If asked for a code", show: captions) {
                        Picker("If asked for a code", selection: $role.codeIfAsked) {
                            ForEach(CodeSource.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
                if role.warning.isEmpty && !addingWarning {
                    Button { addingWarning = true } label: { Image(systemName: "exclamationmark.triangle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Add a warning to the approval prompt")
                        .padding(.bottom, 4)
                }
                DeleteButton(action: onDelete).padding(.bottom, 4)
            }
            if role.usesMail {
                Captioned("Email comes from. Separate several with commas") {
                    TextField("Email comes from", text: $role.mailSender, prompt: Text("no-reply@example.com, example.com"))
                }
            }
            if !role.warning.isEmpty || addingWarning {
                Captioned("Warning on the approval prompt") {
                    TextField("Warning", text: $role.warning, prompt: Text("Reaches every customer org"))
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 2)
    }
}

struct DeleteButton: View {
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove")
    }
}

private enum PasswordKind: String, CaseIterable, Hashable {
    case apple, stored, none
    var label: String {
        switch self {
        case .apple: return "Apple Passwords"
        case .stored: return "Stored in Doorman"
        case .none: return "No password"
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var account: Account
    let appHost: String
    let isTestApp: Bool
    let roles: [Role]
    let captions: Bool
    let onDelete: () -> Void
    @State private var logins: [String] = []
    @State private var looking = false
    @State private var showLogins = false

    private var kind: Binding<PasswordKind> {
        Binding {
            switch account.credential {
            case .applePasswords: return .apple
            case .stored: return .stored
            case .none: return .none
            }
        } set: { value in
            switch value {
            case .apple:
                account.credential = .applePasswords(site: normalizeHost(appHost))
            case .stored: account.credential = .stored
            case .none: account.credential = .none
            }
        }
    }

    private var site: Binding<String> {
        Binding {
            if case let .applePasswords(site) = account.credential { return site }
            return ""
        } set: { account.credential = .applePasswords(site: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Captioned("Account", show: captions) { TextField("Account", text: $account.name, prompt: Text("Prod admin")) }
                    .frame(minWidth: 130)
                Captioned("Role", show: captions) {
                    Picker("Role", selection: $account.roleID) {
                        ForEach(roles) { Text($0.name.isEmpty ? $0.path : $0.name).tag($0.id) }
                    }
                    .fixedSize()
                }
                Captioned("Approval", show: captions) {
                    Picker("Approval", selection: $account.approval) {
                        ForEach(ApprovalRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
                DeleteButton(action: onDelete).padding(.bottom, 4)
            }
            if account.approval == .noPopup, !isTestApp {
                Label("Any agent could sign in to this account without asking you.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Captioned("Login name", show: captions) { TextField("Login name", text: $account.login, prompt: Text("you@example.com")) }
                    .frame(width: 200)
                Captioned("Password", show: captions) {
                    Picker("Password", selection: kind) {
                        ForEach(PasswordKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                switch kind.wrappedValue {
                case .apple:
                    Captioned("Site in Apple Passwords", show: captions) { TextField("Site", text: site, prompt: Text("example.com")) }
                    Button("Find logins") {
                        looking = true
                        Task {
                            logins = await model.appleLogins(site: site.wrappedValue)
                            looking = false
                            showLogins = true
                        }
                    }
                    .disabled(site.wrappedValue.isEmpty || looking)
                    .popover(isPresented: $showLogins) { loginList }
                case .stored:
                    Captioned("Stored password", show: captions) { StoredPasswordField(accountID: account.id) }
                case .none:
                    EmptyView()
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 3)
    }

    private var loginList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if logins.isEmpty {
                Text(model.appleMessage.isEmpty ? "Apple Passwords has no login for that site." : model.appleMessage)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(logins, id: \.self) { login in
                Button(login) {
                    account.login = login
                    showLogins = false
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 320)
    }
}

/// Write-only. You can set or replace a password here, but it's never shown again.
struct StoredPasswordField: View {
    @EnvironmentObject private var model: AppModel
    let accountID: UUID

    private var value: Binding<String> {
        Binding { model.pendingPasswords[accountID] ?? "" } set: { model.pendingPasswords[accountID] = $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        let saved = AppPasswordSource.hasStoredPassword(accountID: accountID)
        SecureField("Password", text: value, prompt: Text(saved ? "Saved. Type to replace it" : "Enter a password")).labelsHidden()
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if model.activity.isEmpty {
                VStack(spacing: 8) {
                    Text("No sign-ins yet").font(.title3)
                    Text("Every attempt shows up here, including ones you denied. Nothing here ever holds a password or code.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.activity) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.time.string(from: entry.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(describe(entry)).lineLimit(1)
                            Text([entry.agent, entry.via, entry.reason].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        StatusText(status: entry.status).font(.callout)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Activity")
    }

    private func describe(_ entry: ActivityEntry) -> String {
        let parts = [entry.app, entry.role, entry.account].filter { !$0.isEmpty }
        return parts.isEmpty ? entry.host : parts.joined(separator: ", ")
    }
}

struct ApplePasswordsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pin = ""
    @State private var testSite = ""
    @State private var found: [String]?

    var body: some View {
        Form {
            Section {
                HStack {
                    statusDot
                    Text(statusText)
                    Spacer()
                    if model.appleState == .notConnected {
                        Button("Connect") { Task { await model.connectApple() } }
                    }
                    if model.appleState == .paired {
                        Button("Disconnect") { Task { await model.disconnectApple() } }
                    }
                }
                if !model.appleMessage.isEmpty {
                    Text(model.appleMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.appleState == .needsPairing {
                Section("Pair with Apple Passwords") {
                    Text("macOS shows a 6-digit code on screen, and you type it here. You'll do this again if Apple's helper forgets the session, usually after a restart.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Start pairing") { Task { await model.beginApplePairing() } }
                        .buttonStyle(.borderedProminent)
                }
            }

            if model.appleState == .waitingForPIN {
                Section("Type the code macOS is showing") {
                    HStack {
                        TextField("6-digit code", text: $pin).textFieldStyle(.roundedBorder).frame(width: 140).labelsHidden()
                        Button("Pair") {
                            let value = pin
                            pin = ""
                            Task { await model.finishApplePairing(pin: value) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pin.count < 4)
                    }
                }
            }

            if model.appleState == .paired {
                Section("Look up a site") {
                    Text("Shows login names only. Looking one up doesn't read a password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("example.com", text: $testSite).textFieldStyle(.roundedBorder).labelsHidden()
                        Button("Look up") { Task { found = await model.appleLogins(site: testSite) } }.disabled(testSite.isEmpty)
                    }
                    if let found {
                        if found.isEmpty {
                            Text("No logins for that site.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(found, id: \.self) { Text($0).font(.callout) }
                    }
                }
            }

            Section {
                Toggle("Sign in to sites I haven't added", isOn: $model.draft.allowUnaddedSites)
                if model.draft.allowUnaddedSites {
                    Captioned("Never use these sites. Separate several with commas") {
                        TextField("Never use these sites", text: $model.draft.neverSites, prompt: Text("mybank.com, brokerage.com"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Text("Sites you haven't added")
            } footer: {
                Text("An agent can ask to sign in to any site with a saved login, without you adding it first. These always ask you first, and that can't be turned off. Agents can tell from the answer whether you have a login on a site, so lookups are limited and logged in Activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("How this works") {
                Text("Apple has no official way in, and its helper only talks to a browser. So Doorman runs a hidden Chrome with one small relay extension, and does the pairing and encryption itself. The relay and hidden Chrome only ever see encrypted data. An account only uses the entry you point it at, and only after you approve the sign-in. macOS may also ask for Touch ID when a password is read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apple Passwords")
    }

    private var statusDot: some View {
        Circle().fill(model.appleState == .paired ? Color.green : Color.orange).frame(width: 8, height: 8)
    }

    private var statusText: String {
        switch model.appleState {
        case .notConnected: return "Not connected"
        case .needsPairing: return "Helper found. Needs pairing"
        case .waitingForPIN: return "Waiting for the code"
        case .paired: return "Connected"
        case let .disabled(text): return text
        }
    }
}

struct EmailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Mailbox", selection: $model.draft.mail.provider) {
                    Text("Not connected").tag(MailProvider.notConnected)
                    Text("Gmail").tag(MailProvider.gmail)
                    Text("IMAP").tag(MailProvider.imap)
                }
            } footer: {
                Text("Doorman only looks during a sign-in you approved, only for that role's sender, and only for mail from the last few minutes. It never stores mail or shows it to an agent, and it can't change or delete anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.draft.mail.provider == .gmail {
                Section("Gmail") {
                    TextField("Client ID", text: $model.draft.mail.gmailClientID)
                    SecureField("Client secret", text: $model.gmailSecretDraft, prompt: Text(model.hasGmailTokens ? "Saved. Type to replace it" : "From Google Cloud"))
                    HStack {
                        Text(model.hasGmailTokens ? "Connected, read-only" : "Not connected").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if model.hasGmailTokens { Button("Disconnect") { model.disconnectMail() } }
                        Button(model.hasGmailTokens ? "Connect again" : "Connect Gmail") { model.connectGmail() }
                    }
                    Text("In Google Cloud, create a project, enable the Gmail API, and create an OAuth client of type Desktop app. Then paste its ID and secret here. Doorman asks only for read-only access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.draft.mail.provider == .imap {
                Section("IMAP") {
                    TextField("Address", text: $model.draft.mail.address, prompt: Text("you@example.com"))
                    TextField("Server", text: $model.draft.mail.imapHost)
                    TextField("Port", value: $model.draft.mail.imapPort, format: .number.grouping(.never))
                    SecureField("App password", text: $model.imapPasswordDraft, prompt: Text(model.hasIMAPPassword ? "Saved. Type to replace it" : "An app password, not your main one"))
                    HStack {
                        Spacer()
                        if model.hasIMAPPassword { Button("Remove") { model.disconnectMail() } }
                        Button("Save password") { model.saveIMAPPassword() }.disabled(model.imapPasswordDraft.isEmpty)
                        Button("Check connection") { Task { await model.checkIMAP() } }
                    }
                }
            }

            if !model.mailMessage.isEmpty {
                Section { Text(model.mailMessage).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Email")
    }
}

struct BrowsersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var report: AccessibilityProbe.Report?

    var body: some View {
        Form {
            Section("Chrome, Brave and Edge") {
                HStack {
                    Circle().fill(model.browserCount > 0 ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(model.browserCount > 0 ? "\(model.browserCount) browser profile\(model.browserCount == 1 ? "" : "s") connected" : "No browser connected yet")
                }
                if model.browserCount == 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Open your extensions page and turn on Developer mode.")
                        Text("2. Show the Doorman extension folder, and drag it onto that page.")
                        Text("3. This page turns green. Claude in Chrome, Playwriter, and Playwright with --extension all work through it.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Open chrome://extensions") { model.openChromeExtensions() }
                        Button("Show extension folder") { model.revealExtension() }
                    }
                }
            }

            Section("Browsers an agent starts itself") {
                Text("Playwright MCP and browser-use can start from a saved session. An agent calls sign_in with session_file set, Doorman signs in inside a hidden browser with no agent attached, and returns a short-lived file for --storage-state or storage_state. It's deleted after 15 minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Use Accessibility for Claude's browser", isOn: $model.draft.useAccessibility)
                HStack {
                    Button("Allow in System Settings") { AccessibilityProbe.requestTrust() }
                    Button("Check Claude's browser") { report = AccessibilityProbe.check() }
                }
                if let report {
                    Label(report.summary, systemImage: report.usable ? "checkmark.circle" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(report.usable ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Claude's browser (experimental)")
            } footer: {
                Text("A Chrome extension can't run in Claude's browser, so this uses macOS Accessibility instead. It's a broad permission: Doorman could see and type into any app, though it only acts after you approve a sign-in. It hasn't been tried against Claude's browser yet. Open that browser on a sign-in page and use the check to see what your Mac exposes. Email links don't work here yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Browsers")
    }
}
