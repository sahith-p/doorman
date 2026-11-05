import Foundation
import Network
import CryptoKit

public struct GmailTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expires: Date
    public init(accessToken: String, refreshToken: String, expires: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expires = expires
    }
}

public protocol GmailTokenStore: Sendable {
    func load() -> GmailTokens?
    func save(_ tokens: GmailTokens?)
}

/// Reads one sender's recent mail through the Gmail API, with the read-only scope. The search goes to
/// Google, so only matching messages are ever fetched.
public struct GmailMailSource: MailSource {
    public static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    /// What Gmail's own header calls it. A message's own copy of the header can't carry this first.
    public static let authServer = "mx.google.com"
    private let clientID: String
    private let clientSecret: @Sendable () -> String
    private let store: GmailTokenStore
    private let session: URLSession
    private let hasStoredTokens: @Sendable () -> Bool

    public init(clientID: String, clientSecret: @escaping @Sendable () -> String, store: GmailTokenStore, session: URLSession = DoormanNetwork.session,
                hasStoredTokens: @escaping @Sendable () -> Bool = { false }) {
        self.hasStoredTokens = hasStoredTokens
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.store = store
        self.session = session
    }

    public static func searchQuery(sender: String, since: Date) -> String {
        "from:\(sender) after:\(Int(since.timeIntervalSince1970))"
    }

    private func accessToken() async throws -> String {
        guard var tokens = store.load() else {
            // Stored but unreadable means macOS refused access, which isn't the same as never connected.
            if hasStoredTokens() { throw MailSourceError.failed("macOS didn't let Doorman read your Gmail connection.") }
            throw MailSourceError.notConnected
        }
        if tokens.expires > Date().addingTimeInterval(60) { return tokens.accessToken }
        let form = ["client_id": clientID, "client_secret": clientSecret(), "refresh_token": tokens.refreshToken, "grant_type": "refresh_token"]
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = object["access_token"] as? String else {
            throw MailSourceError.failed("Google didn't renew access. Connect Gmail again in Doorman.")
        }
        tokens.accessToken = token
        tokens.expires = Date().addingTimeInterval(object["expires_in"] as? Double ?? 3000)
        store.save(tokens)
        return token
    }

    private func get(_ path: String, query: [URLQueryItem], token: String) async throws -> [String: Any] {
        var parts = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        parts.queryItems = query
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MailSourceError.failed("Gmail refused the request.")
        }
        return object
    }

    public func messages(from sender: String, since: Date) async throws -> [RawMail] {
        let token = try await accessToken()
        let list = try await get("messages", query: [.init(name: "q", value: Self.searchQuery(sender: sender, since: since)), .init(name: "maxResults", value: "5")], token: token)
        var out: [RawMail] = []
        for item in (list["messages"] as? [[String: Any]]) ?? [] {
            guard let id = item["id"] as? String else { continue }
            let full = try await get("messages/\(id)", query: [.init(name: "format", value: "raw")], token: token)
            guard let raw = full["raw"] as? String, let data = Self.base64URL(raw) else { continue }
            let millis = Double(full["internalDate"] as? String ?? "") ?? 0
            let received = Date(timeIntervalSince1970: millis / 1000)
            if received >= since { out.append(RawMail(received: received, rfc822: data, authServer: Self.authServer)) }
        }
        return out
    }

    /// The address of the connected account, for the Email page. Reads no message.
    public func profileAddress() async throws -> String {
        let token = try await accessToken()
        let profile = try await get("profile", query: [], token: token)
        return profile["emailAddress"] as? String ?? ""
    }

    static func base64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.sorted().joined(separator: "&").utf8)
    }
}

/// Google's sign-in for a desktop app: opens the browser, catches the redirect on a one-shot localhost
/// port, and swaps the code for tokens. You do this part yourself, in your browser.
public enum GmailAuthorizer {
    public enum Failure: Error { case denied(String), failed(String) }

    public static func authorizationURL(clientID: String, redirect: String, challenge: String, state: String) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GmailMailSource.scope), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
        ]
        return parts.url!
    }

    public static func connect(clientID: String, clientSecret: String, open: @escaping @Sendable (URL) -> Void) async throws -> GmailTokens {
        let verifier = UUID().uuidString + UUID().uuidString
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString

        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let result: String = try await withCheckedThrowingContinuation { continuation in
            let once = LockedValue(false)
            func finish(_ r: Result<String, Error>) {
                if once.value { return }
                once.value = true
                continuation.resume(with: r)
            }
            listener.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    guard let port = listener.port?.rawValue else { return finish(.failure(Failure.failed("no port"))) }
                    open(authorizationURL(clientID: clientID, redirect: "http://127.0.0.1:\(port)/", challenge: challenge, state: state))
                case let .failed(e):
                    finish(.failure(e))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let text = String(decoding: data ?? Data(), as: UTF8.self)
                    let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let items = URLComponents(string: "http://x\(target)")?.queryItems ?? []
                    let page = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<!doctype html><title>Doorman</title><p style=\"font:15px system-ui;margin:60px\">You can close this tab and go back to Doorman.</p>"
                    conn.send(content: Data(page.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    guard items.first(where: { $0.name == "state" })?.value == state else { return }
                    if let code = items.first(where: { $0.name == "code" })?.value {
                        finish(.success(code + "|" + (listener.port.map { String($0.rawValue) } ?? "")))
                    } else {
                        finish(.failure(Failure.denied(items.first(where: { $0.name == "error" })?.value ?? "no code")))
                    }
                }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { finish(.failure(Failure.failed("Timed out waiting for Google."))) }
        }
        let bits = result.split(separator: "|").map(String.init)
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GmailMailSource.formEncode([
            "client_id": clientID, "client_secret": clientSecret, "code": bits[0], "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": "http://127.0.0.1:\(bits[1])/",
        ])
        let (data, response) = try await DoormanNetwork.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String, let refresh = object["refresh_token"] as? String else {
            throw Failure.failed("Google didn't hand over a token. Check the client ID and secret.")
        }
        return GmailTokens(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(object["expires_in"] as? Double ?? 3000))
    }
}
