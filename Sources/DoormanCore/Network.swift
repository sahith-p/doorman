import Foundation

/// Every web request Doorman makes. The default session keeps responses and request headers in a cache
/// file any program can read, which for Gmail means your emails and a token for your whole mailbox.
public enum DoormanNetwork {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    /// Removes what older builds left behind. Safe to run on every launch, since nothing writes there now.
    public static func removeOldCaches(bundleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        for folder in ["Library/Caches", "Library/HTTPStorages"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(folder).appendingPathComponent(bundleID))
        }
    }
}
