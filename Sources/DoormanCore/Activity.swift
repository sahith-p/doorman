import Foundation

/// One line of the Activity log. Names and statuses only, never a password, a code or a mail body.
public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Date
    public var agent: String
    public var app: String
    public var role: String
    public var account: String
    public var host: String
    public var via: String
    public var status: SignInStatus
    public var reason: String

    public init(id: UUID = UUID(), time: Date = Date(), agent: String, app: String = "", role: String = "",
                account: String = "", host: String = "", via: String = "", status: SignInStatus, reason: String = "") {
        self.id = id
        self.time = time
        self.agent = agent
        self.app = app
        self.role = role
        self.account = account
        self.host = host
        self.via = via
        self.status = status
        self.reason = reason
    }
}

public final class ActivityLog: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var entries: [ActivityEntry] = []
    private let limit = 1000
    /// Called after each attempt, for the on-screen status.
    public var onAppend: (@Sendable (ActivityEntry) -> Void)?

    /// With no file it keeps entries in memory, for tests.
    public init(file: URL? = nil) {
        self.url = file
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = text.split(separator: "\n").compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0.utf8)) }
    }

    public func append(_ entry: ActivityEntry) {
        onAppend?(entry)
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        var rewrite = false
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
            rewrite = true
        }
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if rewrite {
            let text = entries.compactMap { (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }.joined(separator: "\n") + "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let data = try? encoder.encode(entry), let line = String(data: data, encoding: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    /// Newest first.
    public func recent(_ count: Int = 200) -> [ActivityEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(count).reversed())
    }
}
