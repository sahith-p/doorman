import SwiftUI
import AppKit
import DoormanUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

@main
struct DoormanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.approvals.current == nil ? "key" : "key.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Doorman", id: "settings") {
            SettingsRoot().environmentObject(model)
        }
        .defaultSize(width: 880, height: 680)
        .windowResizability(.contentMinSize)
    }
}
