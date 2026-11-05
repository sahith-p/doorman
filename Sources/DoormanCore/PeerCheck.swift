import Foundation
import Darwin
import Security

/// Who's on the other end of the socket, as the kernel reports it. Only a browser's own native host gets
/// to be a browser: that's the connection that can receive a password. Agents can connect too, but they
/// only get the agent API, which has no way to carry a secret.
public enum PeerCheck {
    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    public static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return n == size ? pid_t(info.pbi_ppid) : nil
    }

    /// Browsers we'll hand a password to: a bundle identifier plus the developer it must be signed by. A
    /// name alone proves nothing, and anyone with a developer account could use these identifiers.
    private static let browsers: [(id: String, team: String)] = [
        ("com.google.Chrome", "EQHXZ8M8AV"),
        ("com.google.Chrome.canary", "EQHXZ8M8AV"),
        ("com.google.chrome.for.testing", "EQHXZ8M8AV"),
        ("com.brave.Browser", "KL8N8XSYF4"),
        ("com.microsoft.edgemac", "UBF8T346G9"),
    ]

    public static func browserName(pid: pid_t) -> String {
        guard let path = executablePath(pid: pid) else { return "Browser" }
        return (path as NSString).lastPathComponent
    }

    public static func isSignedBrowser(pid: pid_t) -> Bool {
        browsers.contains { isSigned(pid: pid, identifier: $0.id, team: $0.team) }
    }

    /// The real Claude app, signed by Anthropic. Accessibility hands it passwords, and a bundle identifier
    /// alone is just a name another app can copy.
    public static func isSignedClaude(pid: pid_t) -> Bool {
        isSigned(pid: pid, identifier: "com.anthropic.claudefordesktop", team: "Q6L2SF6YDW")
    }

    private static func isSigned(pid: pid_t, identifier: String, team: String) -> Bool {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The content hash of a signed program on disk.
    public static func codeHash(path: String) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path).resolvingSymlinksInPath() as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return uniqueHash(code)
    }

    private static func uniqueHash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }

    /// The content hash of whatever made this connection, from the kernel's record of it. It stops being
    /// valid if that process has since become a different program.
    private static func codeHash(token: audit_token_t) -> Data? {
        var token = token
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return uniqueHash(staticCode)
    }

    /// The browser, if this connection is Doorman's real host and a signed browser started it directly.
    /// Directly matters: a wrapper program sitting between the browser and the real host could read
    /// everything passing through. Chrome only starts it this way because its manifest says so, and
    /// that file can be edited, which is why the parent has to be the browser itself.
    public static func browserOwningHost(channel: LineChannel, expectedHash: Data?) -> pid_t? {
        guard let expectedHash, let token = channel.peerAuditToken,
              codeHash(token: token) == expectedHash else { return nil }
        guard let p = parent(of: channel.peerPID), p > 1, isSignedBrowser(pid: p) else { return nil }
        return p
    }
}
