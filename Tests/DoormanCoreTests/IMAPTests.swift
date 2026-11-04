import XCTest
import Network
@testable import DoormanCore

/// A tiny scripted IMAP server: enough to check what Doorman asks for, and that it never writes.
private final class FakeIMAPServer: @unchecked Sendable {
    let listener: NWListener
    let commands = Box<[String]>([])
    let mail: [String: String]
    let acceptPassword: String
    var port: UInt16 { listener.port!.rawValue }

    init(mail: [String: String], password: String) throws {
        self.mail = mail
        self.acceptPassword = password
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [self] conn in
            conn.start(queue: .global())
            conn.send(content: Data("* OK ready\r\n".utf8), completion: .idempotent)
            read(conn, buffer: Data())
        }
        listener.start(queue: .global())
        ready.wait()
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, _ in
            var buf = buffer + (data ?? Data())
            while let r = buf.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buf.subdata(in: buf.startIndex..<r.lowerBound), as: UTF8.self)
                buf.removeSubrange(buf.startIndex..<r.upperBound)
                handle(line, conn)
            }
            if !done { read(conn, buffer: buf) }
        }
    }

    private func handle(_ line: String, _ conn: NWConnection) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let tag = parts[0], rest = parts.count > 1 ? parts[1] : ""
        commands.value.append(rest)
        var out = ""
        if rest.hasPrefix("LOGIN") {
            out = rest.contains(acceptPassword) ? "\(tag) OK logged in\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] bad\r\n"
        } else if rest.hasPrefix("EXAMINE") {
            out = "* 2 EXISTS\r\n\(tag) OK [READ-ONLY] done\r\n"
        } else if rest.hasPrefix("UID SEARCH") {
            out = "* SEARCH \(mail.keys.sorted().joined(separator: " "))\r\n\(tag) OK done\r\n"
        } else if rest.hasPrefix("UID FETCH") {
            let id = rest.split(separator: " ")[2]
            let body = mail[String(id)] ?? ""
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
            out = "* 1 FETCH (UID \(id) INTERNALDATE \"\(f.string(from: Date()))\" BODY[] {\(body.utf8.count)}\r\n\(body))\r\n\(tag) OK done\r\n"
        } else if rest.hasPrefix("LOGOUT") {
            out = "* BYE\r\n\(tag) OK bye\r\n"
        } else {
            out = "\(tag) BAD what\r\n"
        }
        conn.send(content: Data(out.utf8), completion: .idempotent)
    }
}

final class IMAPTests: XCTestCase {
    private func source(_ server: FakeIMAPServer, password: String = "app-pass") -> IMAPMailSource {
        IMAPMailSource(config: .init(host: "127.0.0.1", port: Int(server.port), username: "me@example.com", useTLS: false), password: { Secret(password) })
    }

    func testReadsAMessageAndExtractsTheCode() async throws {
        let server = try FakeIMAPServer(mail: ["7": demoMail(from: "no-reply@example.com", subject: "Code", body: "Your code is 556677.")], password: "app-pass")
        await server.start()
        let list = try await source(server).messages(from: "no-reply@example.com", since: Date().addingTimeInterval(-60))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(MailExtract.code(in: MailParser.parse(list[0].rfc822)), "556677")
    }

    func testOnlyEverDoesReadOnlyThings() async throws {
        let server = try FakeIMAPServer(mail: ["7": demoMail(from: "a@b.com", subject: "s", body: "b")], password: "app-pass")
        await server.start()
        _ = try await source(server).messages(from: "a@b.com", since: Date().addingTimeInterval(-60))
        let verbs = server.commands.value.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        XCTAssertTrue(verbs.contains { $0.hasPrefix("EXAMINE") })
        XCTAssertFalse(verbs.contains { $0.hasPrefix("SELECT") }, "SELECT could mark mail as read")
        XCTAssertFalse(server.commands.value.contains { $0.contains("STORE") || $0.contains("DELETE") || $0.contains("EXPUNGE") })
        XCTAssertTrue(server.commands.value.contains { $0.contains("BODY.PEEK[]") }, "PEEK keeps mail unread")
        XCTAssertTrue(server.commands.value.contains { $0.contains("FROM \"a@b.com\"") }, "the search names the sender")
    }

    func testBadLoginDoesNotEchoThePassword() async throws {
        let server = try FakeIMAPServer(mail: [:], password: "right")
        await server.start()
        do {
            _ = try await source(server, password: "wrong-secret").messages(from: "a@b.com", since: Date())
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse("\(error)".contains("wrong-secret"))
            XCTAssertEqual(error as? MailSourceError, .failed("The mail server refused the login."))
        }
    }

    func testNoPasswordMeansNotConnected() async {
        let s = IMAPMailSource(config: .init(host: "127.0.0.1", username: "x"), password: { nil })
        do {
            _ = try await s.messages(from: "a@b.com", since: Date())
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MailSourceError, .notConnected)
        }
    }

    func testQuotingCantBreakOutOfTheCommand() {
        XCTAssertEqual(IMAPMailSource.quote(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testGmailQueryNamesTheSenderAndTime() {
        XCTAssertEqual(GmailMailSource.searchQuery(sender: "x@y.com", since: Date(timeIntervalSince1970: 1000)), "from:x@y.com after:1000")
        XCTAssertEqual(GmailMailSource.base64URL("aGk_"), Data([0x68, 0x69, 0x3F]))
    }

    func testGmailAskForReadOnlyScope() {
        let url = GmailAuthorizer.authorizationURL(clientID: "c", redirect: "http://127.0.0.1:1/", challenge: "x", state: "s")
        XCTAssertTrue(url.absoluteString.contains("gmail.readonly"))
        XCTAssertFalse(url.absoluteString.contains("gmail.modify"))
    }
}
