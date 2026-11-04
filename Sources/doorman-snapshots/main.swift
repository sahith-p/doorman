import SwiftUI
import AppKit
import DoormanCore
import DoormanUI

// Dev only. Renders every screen to snapshots/*.png in light and dark, using made-up data, so the UI can
// be looked at without Screen Recording permission or a real sign-in.

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("snapshots")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

@MainActor
func render<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false) {
    // No title bar, so there's no blank strip at the top of the image.
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // A solid background, because a transparent PNG makes dark mode look like white text on white.
    let host = NSHostingView(rootView: view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(origin: .zero, size: size)
    window.contentView = host
    window.orderBack(nil)
    for _ in 0..<12 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    let file = out.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
    try? rep.representation(using: .png, properties: [:])?.write(to: file)
    window.orderOut(nil)
    print(file.lastPathComponent)
}

func sampleSettings() -> DoormanSettings {
    let superadmin = Role(name: "Superadmin", path: "/admin", signIn: .emailCode, mailSender: "no-reply@example.com, login@mail.example.org", warning: "Reaches every customer org")
    let technician = Role(name: "Technician", path: "/technician", signIn: .password, codeIfAsked: .askMe)
    let admin = Role(name: "MSP admin", path: "/", signIn: .password, codeIfAsked: .askMe)
    return DoormanSettings(apps: [
        AppProfile(name: "Acme Production", host: "app.example.com", roles: [superadmin, technician, admin], accounts: [
            Account(name: "Superadmin", roleID: superadmin.id, login: "you@example.com"),
            Account(name: "MSP admin", roleID: admin.id, login: "you@example.com", credential: .applePasswords(site: "app.example.com")),
        ]),
        AppProfile(name: "Acme Staging", host: "staging.example.net", isTest: true),
    ])
}

func sampleActivity() -> [ActivityEntry] {
    let now = Date()
    return [
        ActivityEntry(time: now.addingTimeInterval(-120), agent: "claude-code", app: "Acme Production", role: "Superadmin", account: "Prod superadmin", host: "app.example.com", via: "Google Chrome", status: .signedIn),
        ActivityEntry(time: now.addingTimeInterval(-3600), agent: "playwright", app: "Acme Staging", role: "Technician", account: "Staging tech 66", host: "staging.example.net", via: "Session file", status: .signedIn),
        ActivityEntry(time: now.addingTimeInterval(-7200), agent: "claude-code", app: "Acme Production", role: "Admin", account: "Prod admin", host: "app.example.com", via: "Google Chrome", status: .denied, reason: "user_denied"),
        ActivityEntry(time: now.addingTimeInterval(-9000), agent: "browser-use", host: "unknown-site.io", status: .needsYou, reason: "no_app"),
    ]
}

let prodPrompt = ApprovalRequest(app: "Acme Production", appIsTest: false, role: "Superadmin", roleWarning: "Reaches every customer org", roleWasAsked: false,
                                 accounts: [AccountChoice(id: UUID(), name: "Prod superadmin", login: "you@example.com")], host: "app.example.com", via: "Google Chrome",
                                 windowTitle: "Acme Admin", steps: "Email code from no-reply@example.com or login@mail.example.org", agent: "claude-code", agentReason: "Open the staging deploy page you asked for.")
let pickPrompt = ApprovalRequest(app: "Acme Staging", appIsTest: true, role: "Technician", roleWarning: "", roleWasAsked: true,
                                 accounts: [AccountChoice(id: UUID(), name: "Staging tech 66", login: "tech66@example.com"), AccountChoice(id: UUID(), name: "Staging tech 65", login: "tech65@example.com")],
                                 host: "staging.example.net", via: "Google Chrome", windowTitle: "Technician console", steps: "Password, plus an authenticator code if asked", agent: "claude-code", agentReason: "")

@MainActor
func renderAll() {
    let model = AppModel.shared
    model.mcpPathOverride = "/Applications/Doorman.app/Contents/MacOS/doorman-mcp"
    model.saved = sampleSettings()
    model.draft = model.saved
    model.activity = sampleActivity()
    let settingsSize = CGSize(width: 900, height: 860)

    for dark in [false, true] {
        render("approval-prod", ApprovalView(request: prodPrompt, onApprove: { _ in }, onDeny: {}).fixedSize(), size: CGSize(width: 440, height: 336), dark: dark)
        render("approval-pick", ApprovalView(request: pickPrompt, onApprove: { _ in }, onDeny: {}).fixedSize(), size: CGSize(width: 440, height: 300), dark: dark)
        render("menu", MenuContent().environmentObject(model), size: CGSize(width: 280, height: 240), dark: dark)
        model.selection = .app(model.draft.apps[0].id)
        render("settings-app", SettingsRoot().environmentObject(model), size: settingsSize, dark: dark)
        model.selection = .activity
        render("settings-activity", SettingsRoot().environmentObject(model), size: CGSize(width: 900, height: 500), dark: dark)
        model.selection = .start
        render("settings-start", SettingsRoot().environmentObject(model), size: CGSize(width: 900, height: 740), dark: dark)
        model.selection = .apple
        model.appleState = .needsPairing
        render("settings-apple", SettingsRoot().environmentObject(model), size: CGSize(width: 900, height: 700), dark: dark)
        model.draft.mail.provider = .imap
        model.selection = .email
        render("settings-email", SettingsRoot().environmentObject(model), size: CGSize(width: 900, height: 620), dark: dark)
        model.draft.mail.provider = .notConnected
        model.selection = .browsers
        render("settings-browsers", SettingsRoot().environmentObject(model), size: CGSize(width: 900, height: 680), dark: dark)
        model.changedOutside = true
        model.selection = .app(model.draft.apps[0].id)
        render("settings-changed-outside", SettingsRoot().environmentObject(model), size: CGSize(width: 900, height: 420), dark: dark)
        model.changedOutside = false
    }
    for dark in [false, true] {
        render("prompt-code", CodePromptView(app: "Acme Staging", account: "Superadmin", onSubmit: { _ in }, onCancel: {}).fixedSize(), size: CGSize(width: 400, height: 214), dark: dark)
        render("status-working", StatusView(status: .init(text: "Waiting for the code in your email", detail: "", kind: .working)).fixedSize(), size: CGSize(width: 300, height: 56), dark: dark)
        render("status-done", StatusView(status: .init(text: "Signed in to Acme Staging", detail: "for claude-code", kind: .success)).fixedSize(), size: CGSize(width: 300, height: 56), dark: dark)
    }
    let empty = AppModel()
    render("settings-empty", SettingsRoot().environmentObject(empty), size: CGSize(width: 900, height: 500))
}

/// `doorman-snapshots --icon <file.png>`: draws the app icon.
@MainActor
func renderIcon(to path: String) {
    let view = ZStack {
        RoundedRectangle(cornerRadius: 225, style: .continuous).fill(Color(red: 0.16, green: 0.33, blue: 0.86))
        Image(systemName: "key.fill")
            .font(.system(size: 520, weight: .semibold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(-45))
    }
    .frame(width: 1024, height: 1024)
    let renderer = ImageRenderer(content: view)
    renderer.isOpaque = false
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
        renderIcon(to: CommandLine.arguments[i + 1])
    } else {
        renderAll()
    }
}
