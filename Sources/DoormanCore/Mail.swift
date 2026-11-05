import Foundation

public struct ParsedMail: Sendable {
    public var from: String
    public var subject: String
    public var date: Date?
    public var text: String
    public var html: String
    public var authenticationResults: String
}

/// Reads a raw email into headers and text. Plain parsing, with no AI, so a message can't talk it into
/// anything. Nothing here keeps a message: it's read during one sign-in and dropped.
public enum MailParser {
    public static func parse(_ data: Data) -> ParsedMail {
        let raw = String(decoding: data, as: UTF8.self)
        let (headers, body) = splitHeaders(raw)
        var text = "", html = ""
        walk(headers: headers, body: body, data: data, text: &text, html: &html, depth: 0)
        // Two From headers is a forgery trick: different programs believe different ones.
        let froms = allHeaders(headers, "from")
        return ParsedMail(
            from: froms.count == 1 ? address(from: froms[0]) : "",
            subject: decodeWords(header(headers, "subject") ?? ""),
            date: header(headers, "date").flatMap(parseDate),
            text: text,
            html: html,
            // Only the first: that's the one your own mail server added. A forged message can carry
            // any number of its own further down.
            authenticationResults: header(headers, "authentication-results") ?? "")
    }

    static func splitHeaders(_ raw: String) -> (headers: [(String, String)], body: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        guard let first = parts.first else { return ([], "") }
        var headers: [(String, String)] = []
        for line in first.components(separatedBy: "\n") {
            if let c = line.first, c == " " || c == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]).lowercased(), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return (headers, parts.dropFirst().joined(separator: "\n\n"))
    }

    static func header(_ headers: [(String, String)], _ name: String) -> String? {
        headers.first(where: { $0.0 == name })?.1
    }

    static func allHeaders(_ headers: [(String, String)], _ name: String) -> [String] {
        headers.filter { $0.0 == name }.map { $0.1 }
    }

    static func parameter(_ value: String, _ name: String) -> String? {
        for part in value.components(separatedBy: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            }
        }
        return nil
    }

    private static func walk(headers: [(String, String)], body: String, data: Data, text: inout String, html: inout String, depth: Int) {
        guard depth < 12 else { return }
        let type = (header(headers, "content-type") ?? "text/plain")
        let mime = (type.components(separatedBy: ";").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if mime.hasPrefix("multipart/"), let boundary = parameter(type, "boundary") {
            let parts = body.components(separatedBy: "--" + boundary)
            for part in parts.dropFirst() {
                if part.hasPrefix("--") { break }
                var trimmed = part
                if trimmed.hasPrefix("\n") { trimmed.removeFirst() }
                let (h, b) = splitHeaders(trimmed)
                walk(headers: h, body: b, data: data, text: &text, html: &html, depth: depth + 1)
            }
            return
        }
        guard mime == "text/plain" || mime == "text/html" || mime.isEmpty else { return }
        let decoded = decodeBody(body, encoding: header(headers, "content-transfer-encoding"), charset: parameter(type, "charset"))
        if mime == "text/html" { html += decoded + "\n" } else { text += decoded + "\n" }
    }

    static func decodeBody(_ body: String, encoding: String?, charset: String?) -> String {
        let enc = encoding?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let bytes: Data
        switch enc {
        case "base64":
            bytes = Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined()) ?? Data(body.utf8)
        case "quoted-printable":
            bytes = decodeQuotedPrintable(body)
        default:
            bytes = Data(body.utf8)
        }
        if let cs = charset?.lowercased(), cs.contains("8859") || cs.contains("1252") {
            return String(data: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decodeQuotedPrintable(_ s: String, headerMode: Bool = false) -> Data {
        var out = Data()
        let utf8 = Array(s.utf8)
        var i = 0
        while i < utf8.count {
            let c = utf8[i]
            if c == 0x3D { // =
                if i + 1 < utf8.count, utf8[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < utf8.count, let h = hexValue(utf8[i + 1]), let l = hexValue(utf8[i + 2]) {
                    out.append(UInt8(h << 4 | l))
                    i += 3
                    continue
                }
            }
            if headerMode, c == 0x5F { out.append(0x20); i += 1; continue }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c) - 0x30
        case 0x41...0x46: return Int(c) - 0x41 + 10
        case 0x61...0x66: return Int(c) - 0x61 + 10
        default: return nil
        }
    }

    /// `=?UTF-8?B?...?=` and `=?UTF-8?Q?...?=` in headers.
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?"), let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return s }
        var out = s
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let enc = Range(m.range(at: 2), in: s), let val = Range(m.range(at: 3), in: s) else { continue }
            let data: Data
            if s[enc].lowercased() == "b" {
                data = Data(base64Encoded: String(s[val])) ?? Data()
            } else {
                data = decodeQuotedPrintable(String(s[val]), headerMode: true)
            }
            if let wholeInOut = out.range(of: String(s[whole])) {
                out.replaceSubrange(wholeInOut, with: String(decoding: data, as: UTF8.self))
            }
        }
        return out
    }

    /// `"Name" <a@b.com>` to `a@b.com`, or "" if it isn't exactly one plain address. Quoted names and
    /// comments are removed first, because they can contain text that looks like a different address,
    /// and an encoded name is never decoded here for the same reason.
    static func address(from raw: String) -> String {
        var rest = ""
        var depth = 0, inQuote = false, escaped = false
        for c in raw {
            if escaped { escaped = false; continue }
            if inQuote {
                if c == "\\" { escaped = true } else if c == "\"" { inQuote = false }
                continue
            }
            if depth > 0 {
                if c == "\\" { escaped = true } else if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                continue
            }
            if c == "\"" { inQuote = true } else if c == "(" { depth = 1 } else { rest.append(c) }
        }
        guard !inQuote, depth == 0, !rest.contains(",") else { return "" }
        var candidate = rest
        let opens = rest.filter { $0 == "<" }.count
        if opens > 1 { return "" }
        if opens == 1 {
            guard let open = rest.firstIndex(of: "<"), let close = rest.firstIndex(of: ">"), open < close else { return "" }
            candidate = String(rest[rest.index(after: open)..<close])
        }
        let address = candidate.trimmingCharacters(in: .whitespaces).lowercased()
        guard address.filter({ $0 == "@" }).count == 1, !address.contains(where: \.isWhitespace), !address.hasPrefix("@"), !address.hasSuffix("@") else { return "" }
        return address
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    public static func htmlToText(_ html: String) -> String {
        var s = html
        for pattern in [#"(?is)<style[^>]*>.*?</style>"#, #"(?is)<script[^>]*>.*?</script>"#, #"(?s)<!--.*?-->"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/tr|/h[1-6])[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(s)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x3D;", "="), ("&#61;", "=")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
}

public enum MailExtract {
    /// A sender is an exact address (`no-reply@x.com`) or a whole domain (`x.com`, `@x.com`). From alone
    /// is easy to fake, so your own mail server must also have recorded that the message really came
    /// from that domain. A message with no such record doesn't count.
    public static func senderMatches(_ mail: ParsedMail, expected: String) -> Bool {
        fromMatches(mail, expected: expected) && verified(mail)
    }

    /// Whether the From address is the one expected. On its own this proves nothing.
    public static func fromMatches(_ mail: ParsedMail, expected: String) -> Bool {
        let want = expected.trimmingCharacters(in: .whitespaces).lowercased()
        guard !want.isEmpty, !mail.from.isEmpty else { return false }
        if want.contains("@"), !want.hasPrefix("@") { return mail.from == want }
        let domain = want.hasPrefix("@") ? String(want.dropFirst()) : want
        return mail.from.hasSuffix("@" + domain)
    }

    /// Whether your own mail server wrote the header `verified` is about to trust. If a server adds none,
    /// the first one in the message is whatever the sender put there, so it has to carry the right name.
    /// A comma-separated list is allowed, and a name covers its subdomains (`messagingengine.com`).
    public static func writtenByYourServer(_ mail: ParsedMail, server: String?) -> Bool {
        let wanted = (server ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let section = mail.authenticationResults.lowercased().split(separator: ";", maxSplits: 1).first,
              let name = section.split(whereSeparator: \.isWhitespace).first.map(String.init), !name.contains("=") else { return false }
        return wanted.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// Whether your mail server recorded that the From address's domain really sent this.
    public static func verified(_ mail: ParsedMail) -> Bool {
        guard let domain = mail.from.split(separator: "@").last.map(String.init) else { return false }
        return authenticated(mail.authenticationResults.lowercased(), domain: domain)
    }

    /// DMARC passing for this exact domain, or a DKIM signature from it. An SPF pass alone only speaks
    /// for the envelope sender, which is a different address from the From header.
    static func authenticated(_ auth: String, domain: String) -> Bool {
        if auth.contains("dmarc=fail") { return false }
        if let from = firstMatch(#"dmarc=pass[^;]*?header\.from=([^\s;]+)"#, in: auth), from == domain { return true }
        // A signature from the same organization counts, the way DMARC itself treats it: mail from
        // staging.example.com can be signed by example.com.
        if let signer = firstMatch(#"dkim=pass[^;]*?header\.[id]=@?([^\s;]+)"#, in: auth), signer.contains("."),
           signer == domain || signer.hasSuffix("." + domain) || domain.hasSuffix("." + signer) { return true }
        return false
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func clean(_ code: String) -> String {
        code.filter { !$0.isWhitespace && $0 != "-" }
    }

    /// The labelled number wins, so an order number or a year elsewhere in the mail isn't picked up.
    public static func code(in mail: ParsedMail) -> String? {
        let body = mail.text.isEmpty ? MailParser.htmlToText(mail.html) : mail.text + "\n" + MailParser.htmlToText(mail.html)
        let label = #"(?:code|passcode|otp|pin|one[- ]time|verification|verify|security)"#
        let digits = #"(\d(?:[ -]?\d){3,7})"#
        let after = "(?i)\(label)\\b[^0-9\\n]{0,60}?\\b\(digits)\\b"
        let before = "(?i)\\b\(digits)\\b[^0-9\\n]{0,30}?\(label)\\b"
        for source in [mail.subject, body] {
            if let hit = firstMatch(after, in: source) { return clean(hit) }
            if let hit = firstMatch(before, in: source) { return clean(hit) }
        }
        for line in body.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^\d(?:[ -]?\d){3,7}$"#, options: .regularExpression) != nil {
                let cleaned = clean(t)
                if cleaned.count == 4, cleaned.hasPrefix("19") || cleaned.hasPrefix("20") { continue }
                return cleaned
            }
        }
        let lower = body.lowercased() + " " + mail.subject.lowercased()
        if lower.range(of: label.replacingOccurrences(of: "(?:", with: "("), options: .regularExpression) != nil {
            for line in body.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.range(of: #"^(?=[A-Z0-9-]*[0-9])(?=[A-Z0-9-]*[A-Z])[A-Z0-9-]{6,12}$"#, options: .regularExpression) != nil { return t }
            }
        }
        return nil
    }

    /// Only ever a link on an allowed host. The browser check in the engine still applies after it opens.
    public static func link(in mail: ParsedMail, allowedHosts: [String]) -> URL? {
        let allowed = Set(allowedHosts.map(normalizeHost).filter { !$0.isEmpty })
        var candidates: [URL] = []
        let source = mail.html + "\n" + mail.text
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>\)\]]+"#) else { return nil }
        for m in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let r = Range(m.range, in: source) else { continue }
            let raw = MailParser.decodeEntities(String(source[r])).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            guard let url = URL(string: raw), let host = hostKey(url), allowed.contains(host) else { continue }
            let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
            guard url.scheme?.lowercased() == "https" || isLocal else { continue }
            if !candidates.contains(url) { candidates.append(url) }
        }
        let ignore = #"(?i)(unsubscribe|privacy|terms|preferences|help|support|\.(png|jpe?g|gif|svg|css)(\?|$))"#
        let wanted = #"(?i)(token|magic|verify|login|log-in|signin|sign-in|auth|confirm|session|code)"#
        let usable = candidates.filter { $0.absoluteString.range(of: ignore, options: .regularExpression) == nil }
        if let best = usable.first(where: { ($0.path + "?" + ($0.query ?? "")).range(of: wanted, options: .regularExpression) != nil }) {
            return best
        }
        return usable.count == 1 ? usable[0] : nil
    }
}
