import Foundation
import Network

/// Reads one sender's recent mail over IMAP, read-only. Each look is a short connection: log in, open the
/// inbox with EXAMINE (which can't change anything), search for this sender, fetch a few, log out.
public struct IMAPMailSource: MailSource {
    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var useTLS: Bool
        /// See `RawMail.authServer`.
        public var authServer: String?
        public init(host: String, port: Int = 993, username: String, useTLS: Bool = true, authServer: String? = nil) {
            self.authServer = authServer
            self.host = host
            self.port = port
            self.username = username
            self.useTLS = useTLS
        }
    }

    private let config: Config
    private let password: @Sendable () -> Secret?

    public init(config: Config, password: @escaping @Sendable () -> Secret?) {
        self.config = config
        self.password = password
    }

    public func messages(from sender: String, since: Date) async throws -> [RawMail] {
        guard let password = password() else { throw MailSourceError.notConnected }
        let session = IMAPSession(config: config)
        try await session.open()
        defer { session.close() }
        _ = try await session.command("LOGIN \(Self.quote(config.username)) \(Self.quote(password.reveal()))")
        _ = try await session.command("EXAMINE INBOX")
        // IMAP only searches by date, so the time is checked again once the mail has been read.
        let day = Self.imapDate(since)
        let search = try await session.command("UID SEARCH SINCE \(day) FROM \(Self.quote(sender))")
        let ids = Self.searchResults(search.text)
        var out: [RawMail] = []
        for id in ids.suffix(8).reversed() {
            let reply = try await session.command("UID FETCH \(id) (BODY.PEEK[] INTERNALDATE)")
            guard let literal = reply.literals.first else { continue }
            let date = Self.internalDate(reply.text) ?? Date()
            if date >= since { out.append(RawMail(received: date, rfc822: literal, authServer: config.authServer)) }
        }
        _ = try? await session.command("LOGOUT")
        return out
    }

    /// Checks the settings work, and says how many recent messages it can see. Reads no message.
    public func check() async throws -> Int {
        guard let password = password() else { throw MailSourceError.notConnected }
        let session = IMAPSession(config: config)
        try await session.open()
        defer { session.close() }
        _ = try await session.command("LOGIN \(Self.quote(config.username)) \(Self.quote(password.reveal()))")
        _ = try await session.command("EXAMINE INBOX")
        let search = try await session.command("UID SEARCH SINCE \(Self.imapDate(Date().addingTimeInterval(-86400)))")
        _ = try? await session.command("LOGOUT")
        return Self.searchResults(search.text).count
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd-MMM-yyyy"
        // A day earlier covers time zone differences. The exact time is checked after reading.
        return f.string(from: date.addingTimeInterval(-86400))
    }

    static func searchResults(_ text: String) -> [String] {
        for line in text.components(separatedBy: "\r\n") where line.hasPrefix("* SEARCH") {
            return line.dropFirst("* SEARCH".count).split(separator: " ").map(String.init)
        }
        return []
    }

    static func internalDate(_ text: String) -> Date? {
        guard let r = text.range(of: #"INTERNALDATE "([^"]+)""#, options: .regularExpression) else { return nil }
        let value = text[r].replacingOccurrences(of: "INTERNALDATE ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}

final class IMAPSession: @unchecked Sendable {
    struct Reply {
        var text: String
        var literals: [Data]
    }

    private let config: IMAPMailSource.Config
    private var connection: NWConnection?
    private var buffer = Data()
    private var counter = 0

    init(config: IMAPMailSource.Config) { self.config = config }

    func open() async throws {
        let params: NWParameters = config.useTLS ? NWParameters(tls: NWProtocolTLS.Options()) : .tcp
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(integerLiteral: UInt16(config.port)), using: params)
        connection = conn
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = LockedValue(false)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !once.value { once.value = true; c.resume() }
                case let .failed(error), let .waiting(error):
                    if !once.value { once.value = true; c.resume(throwing: MailSourceError.failed("Couldn't reach the mail server: \(error.localizedDescription)")) }
                case .cancelled:
                    if !once.value { once.value = true; c.resume(throwing: MailSourceError.failed("The mail server took too long.")) }
                default:
                    break
                }
            }
            conn.start(queue: .global())
            // A stuck server can't hold up a sign-in: this ends the whole conversation with it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { conn.cancel() }
        }
        _ = try await readUntil { self.buffer.range(of: Data("\r\n".utf8)) != nil }
        if let r = buffer.range(of: Data("\r\n".utf8)) { buffer.removeSubrange(buffer.startIndex..<r.upperBound) }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func receiveMore() async throws {
        guard let connection else { throw MailSourceError.failed("not connected") }
        let chunk: Data = try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let error { c.resume(throwing: MailSourceError.failed(error.localizedDescription)); return }
                if let data, !data.isEmpty { c.resume(returning: data); return }
                if done { c.resume(throwing: MailSourceError.failed("the mail server closed the connection")); return }
                c.resume(returning: Data())
            }
        }
        buffer.append(chunk)
    }

    private func readUntil(_ condition: () -> Bool) async throws -> Bool {
        var spins = 0
        while !condition() {
            try await receiveMore()
            spins += 1
            if spins > 200_000 { throw MailSourceError.failed("mail reply too long") }
        }
        return true
    }

    func command(_ text: String) async throws -> Reply {
        counter += 1
        let tag = "D\(counter)"
        guard let connection else { throw MailSourceError.failed("not connected") }
        let out = Data("\(tag) \(text)\r\n".utf8)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: out, completion: .contentProcessed { error in
                if let error { c.resume(throwing: MailSourceError.failed(error.localizedDescription)) } else { c.resume() }
            })
        }
        var reply = Reply(text: "", literals: [])
        while true {
            _ = try await readUntil { self.buffer.range(of: Data("\r\n".utf8)) != nil }
            let end = buffer.range(of: Data("\r\n".utf8))!
            let line = String(decoding: buffer.subdata(in: buffer.startIndex..<end.lowerBound), as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            reply.text += line + "\r\n"
            // A literal: `{1234}` at the end of the line, then that many raw bytes.
            if line.hasSuffix("}"), let open = line.lastIndex(of: "{"), let count = Int(line[line.index(after: open)...].dropLast()) {
                _ = try await readUntil { self.buffer.count >= count }
                reply.literals.append(buffer.prefix(count))
                buffer.removeFirst(count)
                continue
            }
            if line.hasPrefix(tag + " ") {
                let status = line.dropFirst(tag.count + 1)
                if status.hasPrefix("OK") { return reply }
                // Never echo the command: a failed LOGIN line would hold the password.
                let verb = text.split(separator: " ").first.map(String.init) ?? "command"
                throw MailSourceError.failed(verb == "LOGIN" ? "The mail server refused the login." : "The mail server refused \(verb).")
            }
        }
    }
}
