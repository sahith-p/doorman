import SwiftUI
import AppKit
import LocalAuthentication
import DoormanCore

/// Asks for Touch ID. Falls back to your Mac password if Touch ID isn't available.
public enum TouchID {
    public static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Floats over whatever you're doing and takes typing, without bringing Doorman's windows forward or
/// taking you out of the app you're in.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(view: NSView, interactive: Bool) {
        // Borderless, because a titled window keeps an empty strip at the top for its title bar. The rounded
        // card itself is drawn by `floatingCard`.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isFloatingPanel = true
        ignoresMouseEvents = !interactive
        contentView = view
    }

    /// Near the top of the screen you're looking at, where it's easy to see.
    func place(topRight: Bool) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        if let view = contentView {
            view.layoutSubtreeIfNeeded()
            setContentSize(view.fittingSize)
        }
        let x = topRight ? area.maxX - frame.width - 16 : area.midX - frame.width / 2
        let y = area.maxY - frame.height - (topRight ? 12 : 56)
        setFrameOrigin(NSPoint(x: x, y: y))
        invalidateShadow()
    }
}

extension View {
    /// The look of every floating popup: compact, rounded, and readable over anything.
    func floatingCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

@MainActor
public final class ApprovalCenter: ObservableObject {
    public struct Pending: Identifiable {
        public var id: UUID { request.id }
        public let request: ApprovalRequest
        let finish: (ApprovalDecision) -> Void
    }
    public struct PendingCode: Identifiable {
        public let id = UUID()
        public let app: String
        public let account: String
        let finish: (Secret?) -> Void
    }
    public struct Status: Equatable {
        public enum Kind { case working, success, problem }
        public var text: String
        public var detail: String
        public var kind: Kind
        public init(text: String, detail: String, kind: Kind) {
            self.text = text
            self.detail = detail
            self.kind = kind
        }
    }

    @Published public private(set) var current: Pending?
    @Published public private(set) var currentCode: PendingCode?
    @Published public private(set) var status: Status?
    private var queue: [Pending] = []
    private var panel: FloatingPanel?
    private var statusPanel: FloatingPanel?
    private var statusHide: DispatchWorkItem?
    public var promptTimeout: TimeInterval = 120

    public init() {}

    nonisolated func ask(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.enqueue(Pending(request: request) { continuation.resume(returning: $0) })
            }
        }
    }

    nonisolated func askCode(app: String, account: String) async -> Secret? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // One at a time. A second one is answered with nothing, not left hanging.
                guard self.currentCode == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let pending = PendingCode(app: app, account: account) { continuation.resume(returning: $0) }
                self.currentCode = pending
                self.showPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + self.promptTimeout) { [weak self] in
                    guard let self, self.currentCode?.id == pending.id else { return }
                    self.cancelCode()
                }
            }
        }
    }

    private func enqueue(_ pending: Pending) {
        // An agent can't bury you in prompts until one gets a reflex tap.
        guard queue.count < 2 else {
            pending.finish(.denied)
            return
        }
        queue.append(pending)
        let id = pending.id
        DispatchQueue.main.asyncAfter(deadline: .now() + promptTimeout) { [weak self] in
            self?.expire(id)
        }
        advance()
    }

    private func expire(_ id: UUID) {
        if current?.id == id {
            finishCurrent(.timedOut)
        } else if let i = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: i).finish(.timedOut)
        }
    }

    private func advance() {
        guard current == nil, currentCode == nil else { return }
        guard !queue.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        current = queue.removeFirst()
        showPanel()
    }

    private func finishCurrent(_ decision: ApprovalDecision) {
        guard let pending = current else { return }
        current = nil
        pending.finish(decision)
        advance()
    }

    public func approve(accountID: UUID) {
        guard let request = current?.request else { return }
        // Apple's Touch ID comes straight after this, so one here as well would only get in the way. The
        // engine asks for Doorman's own if Apple's doesn't appear.
        if request.accounts.first(where: { $0.id == accountID })?.touchIDFollows == true {
            finishCurrent(.approved(accountID: accountID))
            return
        }
        // Written from Doorman's own settings only. Nothing the agent wrote goes into the system sheet.
        let reason = request.role.isEmpty ? "sign in to \(request.app)" : "sign in to \(request.app) as \(request.role)"
        let id = request.id
        Task { @MainActor in
            let ok = await TouchID.confirm(reason: reason)
            guard current?.id == id else { return }
            if ok { finishCurrent(.approved(accountID: accountID)) }
            // A cancelled Touch ID sheet leaves the prompt up, so you can still Approve or Deny.
        }
    }

    public func deny() { finishCurrent(.denied) }

    public func submitCode(_ code: String) {
        guard let pending = currentCode else { return }
        currentCode = nil
        pending.finish(code.isEmpty ? nil : Secret(code))
        advance()
    }

    public func cancelCode() {
        guard let pending = currentCode else { return }
        currentCode = nil
        pending.finish(nil)
        advance()
    }

    private func showPanel() {
        if panel == nil {
            let host = NSHostingView(rootView: ApprovalPanelRoot(center: self))
            panel = FloatingPanel(view: host, interactive: true)
        }
        panel?.place(topRight: false)
        // Without activating Doorman: its settings window stays where it is, and so does your app.
        panel?.orderFrontRegardless()
        panel?.makeKey()
        DispatchQueue.main.async { [weak self] in self?.panel?.place(topRight: false) }
    }

    /// A small note in the corner saying what's happening. It takes no clicks and goes away by itself.
    public func show(_ next: Status, hideAfter: TimeInterval?) {
        status = next
        if statusPanel == nil {
            statusPanel = FloatingPanel(view: NSHostingView(rootView: StatusPanelRoot(center: self)), interactive: false)
        }
        statusPanel?.place(topRight: true)
        statusPanel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.statusPanel?.place(topRight: true) }
        statusHide?.cancel()
        guard let hideAfter else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.statusPanel?.orderOut(nil)
            self?.status = nil
        }
        statusHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
    }
}

struct ApprovalPanelRoot: View {
    @ObservedObject var center: ApprovalCenter

    var body: some View {
        Group {
            if let code = center.currentCode {
                CodePromptView(app: code.app, account: code.account, onSubmit: { center.submitCode($0) }, onCancel: { center.cancelCode() })
                    .id(code.id)
            } else if let pending = center.current {
                ApprovalView(request: pending.request, onApprove: { center.approve(accountID: $0) }, onDeny: { center.deny() })
                    .id(pending.id)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}

public struct ApprovalView: View {
    let request: ApprovalRequest
    let onApprove: (UUID) -> Void
    let onDeny: () -> Void
    @State private var selection: UUID?
    @State private var showDetails = false

    public init(request: ApprovalRequest, onApprove: @escaping (UUID) -> Void, onDeny: @escaping () -> Void) {
        self.request = request
        self.onApprove = onApprove
        self.onDeny = onDeny
        _selection = State(initialValue: request.suggestedAccountID)
    }

    private var chosen: UUID? { selection ?? (request.accounts.count == 1 ? request.accounts.first?.id : nil) }
    private var chosenAccount: AccountChoice? { request.accounts.first { $0.id == chosen } }
    private var subtitle: String {
        let parts = [request.role, chosenAccount?.login ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? "Choose a login" : "as " + parts.joined(separator: ", ")
    }
    private var touchIDFollows: Bool { chosenAccount?.touchIDFollows ?? false }
    /// Apple's sheet names the hidden browser and can't be renamed, so say so before it appears.
    private var appleSheetNote: String? {
        guard chosenAccount?.passwordSite != nil else { return nil }
        let browser = HiddenChrome.browserName ?? "your browser"
        let first = touchIDFollows ? "Touch ID is next, and it will say \(browser)." : "Apple Passwords may ask for Touch ID too, and it will say \(browser)."
        return "\(first) That's the hidden copy Doorman uses to reach Apple Passwords."
    }
    private var siteMismatch: String? {
        guard let site = chosenAccount?.passwordSite, !Approval.siteMatches(site: site, host: request.host) else { return nil }
        return site
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: touchIDFollows ? "key.fill" : "touchid")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Sign in to \(request.app)?").font(.headline).fixedSize(horizontal: false, vertical: true)
                        if !request.appIsTest { Tag(text: "Real site", color: .orange) }
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if request.accounts.count > 1 {
                Picker("Account", selection: $selection) {
                    Text("Choose an account").tag(UUID?.none)
                    ForEach(request.accounts) { Text($0.name == $0.login ? $0.login : "\($0.name) (\($0.login))").tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                if let suggested = request.suggestedAccountID, selection == suggested {
                    Label("\(request.agent) picked this one, not verified. You can change it.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !request.roleWarning.isEmpty {
                Label(request.roleWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if let site = siteMismatch {
                Label("Uses the Apple Passwords entry for \(site), which isn't this site", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.roleWasAsked {
                Label("The agent asked for this role by name", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("\(request.agent) says, not verified:").font(.caption).foregroundStyle(.secondary)
                Text(request.agentReason.isEmpty ? "No reason given" : request.agentReason)
                    .font(.caption)
                    .foregroundStyle(request.agentReason.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = appleSheetNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Details", isExpanded: $showDetails) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Site").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(request.host).textSelection(.enabled)
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
                        }
                    }
                    GridRow {
                        Text("Browser").foregroundStyle(.secondary)
                        Text(request.windowTitle.isEmpty ? request.via : "\(request.via), \"\(request.windowTitle)\"").lineLimit(1)
                    }
                    GridRow {
                        Text("Steps").foregroundStyle(.secondary)
                        Text(request.steps).fixedSize(horizontal: false, vertical: true)
                    }
                    if let site = chosenAccount?.passwordSite {
                        GridRow {
                            Text("Password").foregroundStyle(.secondary)
                            Text("Apple Passwords, \(site)")
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: onDeny) { Text("Deny").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let chosen { onApprove(chosen) }
                } label: {
                    Label("Approve", systemImage: touchIDFollows ? "checkmark" : "touchid").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(14)
        .frame(width: 340)
        .floatingCard()
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Ready to type in: the box has focus as soon as it appears, and Return sends it.
public struct CodePromptView: View {
    let app: String
    let account: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    public init(app: String, account: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.app = app
        self.account = account
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Enter the code").font(.headline)
                Text("for \(app). Doorman enters it, and the agent never sees it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("", text: $code, prompt: Text("123456"))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .focused($focused)
                .onSubmit { if !code.isEmpty { onSubmit(code) } }
            HStack(spacing: 8) {
                Button(action: onCancel) { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button { onSubmit(code) } label: { Text("Enter code").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
        .floatingCard()
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct StatusPanelRoot: View {
    @ObservedObject var center: ApprovalCenter
    var body: some View {
        if let status = center.status { StatusView(status: status) } else { Color.clear.frame(width: 1, height: 1) }
    }
}

public struct StatusView: View {
    let status: ApprovalCenter.Status
    public init(status: ApprovalCenter.Status) { self.status = status }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch status.kind {
                case .working: ProgressView().controlSize(.mini)
                case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if !status.detail.isEmpty {
                    Text(status.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(width: 290, alignment: .leading)
        .floatingCard()
    }
}

/// What the engine calls. It hands everything to the window on the main thread.
public struct AppApprover: Approver {
    let center: ApprovalCenter
    public func approve(_ request: ApprovalRequest) async -> ApprovalDecision { await center.ask(request) }
    public func askForCode(app: String, account: String) async -> Secret? {
        await center.askCode(app: app, account: account)
    }
    public func confirmFingerprint(app: String, role: String) async -> Bool {
        await TouchID.confirm(reason: role.isEmpty ? "sign in to \(app)" : "sign in to \(app) as \(role)")
    }
}
