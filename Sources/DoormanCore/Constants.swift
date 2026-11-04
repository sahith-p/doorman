import Foundation

public enum DoormanConstants {
    public static let fillExtensionID = "fdmdmjmgcdhfcpecmpgnkflnemnnmhkc"
    /// The ID Apple's helper allows. The relay extension gets it from Apple's public key.
    public static let appleExtensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"
    public static let nativeHostName = "ai.doorman.host"
    public static let keychainService = "ai.doorman"

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Doorman")
    }

    /// The override is for the e2e test only. An installed build ignores it, so an agent can't point the
    /// real app's parts somewhere else.
    public static var socketPath: String {
        if Bundle.main.bundleURL.pathExtension != "app",
           let override = ProcessInfo.processInfo.environment["DOORMAN_SOCKET"], !override.isEmpty { return override }
        return supportDirectory.appendingPathComponent("doorman.sock").path
    }
}
