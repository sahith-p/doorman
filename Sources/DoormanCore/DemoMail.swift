import Foundation

/// The demo site's fake mailbox, for trying Doorman with no real email. Only reachable for senders at
/// `doorman.test`, a reserved domain nothing real can send from, and only over localhost.
public struct DemoMailSource: MailSource {
    public static let senderDomain = "doorman.test"
    private let port: Int

    public init(port: Int = 8765) { self.port = port }

    public func messages(from sender: String, since: Date) async throws -> [RawMail] {
        guard let url = URL(string: "http://localhost:\(port)/__mail") else { return [] }
        let (data, _) = try await DoormanNetwork.session.data(from: url)
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let raw = item["raw"] as? String, let at = item["at"] as? Double else { return nil }
            let received = Date(timeIntervalSince1970: at / 1000)
            return received >= since ? RawMail(received: received, rfc822: Data(raw.utf8), authServer: "demo") : nil
        }.reversed()
    }
}

/// Sends a role's mail lookup to the right place: the demo mailbox for demo senders, your real mailbox
/// for everything else.
public struct RoutingMailSource: MailSource {
    private let real: MailSource
    private let demo: MailSource

    public init(real: MailSource, demo: MailSource = DemoMailSource()) {
        self.real = real
        self.demo = demo
    }

    public func messages(from sender: String, since: Date) async throws -> [RawMail] {
        if sender.lowercased().hasSuffix(DemoMailSource.senderDomain) { return try await demo.messages(from: sender, since: since) }
        return try await real.messages(from: sender, since: since)
    }
}

public struct NoMailSource: MailSource {
    public init() {}
    public func messages(from sender: String, since: Date) async throws -> [RawMail] { throw MailSourceError.notConnected }
}
