import SwiftUI
import AppKit
import DoormanCore

public struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Doorman").font(.headline)
                Spacer()
                if model.changedOutside {
                    Tag(text: "Needs review", color: .orange)
                } else if model.saved.paused {
                    Tag(text: "Paused", color: .orange)
                } else {
                    Tag(text: "Running", color: .green)
                }
            }
            .padding(12)

            if let pending = model.approvals.current {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for you").font(.caption).foregroundStyle(.secondary)
                    Label(pending.request.app, systemImage: "lock.fill")
                    Text(pending.request.agent).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                if model.activity.isEmpty {
                    Text("No sign-ins yet").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.activity.prefix(4)) { entry in
                    HStack {
                        Text(entry.app.isEmpty ? entry.host : entry.app).lineLimit(1)
                        Spacer()
                        StatusText(status: entry.status)
                    }
                    .font(.callout)
                }
            }
            .padding(12)

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: "Accounts and activity", icon: "gearshape") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if model.saved.paused {
                    MenuRow(title: "Turn sign-ins back on", icon: "play.fill") { model.setPaused(false) }
                } else {
                    MenuRow(title: "Pause all sign-ins", icon: "pause.fill", tint: .red) { model.setPaused(true) }
                }
                MenuRow(title: "Quit Doorman", icon: "power") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 280)
    }
}

struct MenuRow: View {
    let title: String
    let icon: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct StatusText: View {
    let status: SignInStatus
    var body: some View {
        Text(label).foregroundStyle(color)
    }
    private var label: String {
        switch status {
        case .signedIn: return "Signed in"
        case .denied: return "Denied"
        case .timeout: return "Timed out"
        case .needsYou: return "Needs you"
        case .failed: return "Failed"
        case .paused: return "Paused"
        case .pending: return "Waiting"
        }
    }
    private var color: Color {
        switch status {
        case .signedIn: return .green
        case .denied, .failed: return .red
        default: return .orange
        }
    }
}
