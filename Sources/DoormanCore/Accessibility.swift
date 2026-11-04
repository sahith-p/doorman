import Foundation
import AppKit
import ApplicationServices

/// Reaching Claude's built-in browser, which a Chrome extension can't. This goes through macOS
/// Accessibility, the way 1Password's Universal Autofill works in any app.
///
/// EXPERIMENTAL. Accessibility permission wasn't granted while this was written, so it has never run
/// against Claude's browser. The Browsers page has a check that reports what this Mac really exposes.
public enum AccessibilityProbe {
    public static let claudeBundleID = "com.anthropic.claudefordesktop"

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public struct Report: Sendable, Equatable {
        public var trusted: Bool
        public var appRunning: Bool
        public var pages: [String]
        public var addressVisible: Bool
        public var passwordFields: Int
        public var textFields: Int
        public var asDictionary: [String: Any] {
            ["trusted": trusted, "claude_running": appRunning, "pages": pages, "address_visible": addressVisible,
             "password_fields": passwordFields, "text_fields": textFields, "usable": usable, "summary": summary]
        }

        public var summary: String {
            if !trusted { return "Doorman doesn't have Accessibility permission yet." }
            if !appRunning { return "Claude isn't running." }
            let sites = pages.filter { !$0.contains("no address") && $0 != "claude.ai" }
            if sites.isEmpty { return "Doorman can't see a page in Claude's browser. The pane has to be showing, with a site open in it." }
            return "Doorman can see \(sites.joined(separator: ", ")) in Claude's browser, with \(passwordFields) password field\(passwordFields == 1 ? "" : "s")."
        }
        public var usable: Bool { trusted && appRunning && pages.contains { !$0.contains("no address") && $0 != "claude.ai" } }
    }

    public static func check() -> Report {
        var report = Report(trusted: isTrusted, appRunning: false, pages: [], addressVisible: false, passwordFields: 0, textFields: 0)
        guard report.trusted, let root = claudeRoot() else { return report }
        report.appRunning = true
        for area in AX.webAreas(root) {
            if let url = AX.url(area), let host = hostKey(url) {
                report.pages.append(host)
                report.addressVisible = true
            } else {
                report.pages.append("a page with no address")
            }
            let fields = AX.fields(area)
            report.passwordFields += fields.filter(\.isSecure).count
            report.textFields += fields.filter { !$0.isSecure }.count
        }
        return report
    }

    static func claudeRoot() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // An Electron app only builds its accessibility tree when something asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return root
    }
}

enum AX {
    static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String { attr(element, name) as? String ?? "" }

    static func children(_ element: AXUIElement) -> [AXUIElement] { attr(element, "AXChildren") as? [AXUIElement] ?? [] }

    static func url(_ element: AXUIElement) -> URL? { attr(element, "AXURL") as? URL }

    static func walk(_ element: AXUIElement, depth: Int = 0, budget: inout Int, visit: (AXUIElement, String) -> Bool) {
        guard depth < 90, budget > 0 else { return }
        budget -= 1
        let role = string(element, "AXRole")
        guard visit(element, role) else { return }
        for child in children(element) { walk(child, depth: depth + 1, budget: &budget, visit: visit) }
    }

    /// Top-level web pages. A frame inside a page isn't a page of its own.
    static func webAreas(_ root: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var budget = 80_000
        walk(root, budget: &budget) { element, role in
            if role == "AXWebArea" {
                out.append(element)
                return false
            }
            return true
        }
        return out
    }

    struct Field {
        let element: AXUIElement
        let isSecure: Bool
        let words: String
    }

    static func fields(_ area: AXUIElement) -> [Field] {
        var out: [Field] = []
        var budget = 40_000
        walk(area, budget: &budget) { element, role in
            // An embedded frame is its own page, possibly from another site.
            if role == "AXWebArea", !CFEqual(element, area) { return false }
            if role == "AXTextField" {
                let words = ["AXTitle", "AXDescription", "AXPlaceholderValue", "AXIdentifier", "AXDOMIdentifier", "AXHelp"].map { string(element, $0) }.joined(separator: " ").lowercased()
                out.append(Field(element: element, isSecure: string(element, "AXSubrole") == "AXSecureTextField", words: words))
                return false
            }
            return true
        }
        return out
    }

    static func buttons(_ area: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var budget = 40_000
        walk(area, budget: &budget) { element, role in
            if role == "AXWebArea", !CFEqual(element, area) { return false }
            if role == "AXButton" { out.append(element) }
            return true
        }
        return out
    }
}

/// Fills a page in Claude's browser. Each call finds the page again and re-checks its address, so nothing
/// is typed into a page that moved. Never uses the clipboard, since agents can read that.
public struct AccessibilityAdapter: BrowserAdapter {
    public let name = "Claude's browser"
    public init() {}

    private static let codeRe = #"(one[- ]?time|otp|2fa|mfa|two[- ]?factor|verification|passcode|security code|\bcode\b|\bdigit\b)"#
    private static let hintRe = #"(sign[- ]?in|log[- ]?in|verify|two[- ]?(factor|step)|one[- ]?time|verification|authenticat|enter (the|your) code|send (me )?(a )?code|magic link|check your email)"#
    private static let userRe = #"(user|login|email|e-mail|account|identifier)"#
    private static let goRe = #"(?i)(sign[- ]?in|log[- ]?in|continue|next|verify|submit|confirm|send)"#
    private static let notThisRe = #"(?i)(cancel|back|forgot|reset|sign[- ]?up|register|create|delete|remove|google|microsoft|apple|github|sso|passkey|show|hide|magic link)"#

    private func area(_ tab: String) throws -> AXUIElement {
        guard let root = AccessibilityProbe.claudeRoot(), let i = Int(tab) else { throw BrowserError.disconnected }
        let areas = AX.webAreas(root)
        guard i < areas.count else { throw BrowserError.disconnected }
        return areas[i]
    }

    public func tabs() async throws -> [TabInfo] {
        guard let root = AccessibilityProbe.claudeRoot() else { return [] }
        return AX.webAreas(root).enumerated().compactMap { i, area in
            guard let url = AX.url(area) else { return nil }
            return TabInfo(id: String(i), url: url.absoluteString, title: AX.string(area, "AXTitle"), active: true)
        }
    }

    public func inspect(tab: String) async throws -> PageState {
        let page = try area(tab)
        guard let url = AX.url(page) else { throw BrowserError.failed("no address") }
        let fields = AX.fields(page)
        // One password box is a sign-in. More than that is a sign-up or change-password form.
        let password = fields.filter(\.isSecure).count == 1
        let code = !password && fields.contains { $0.words.range(of: Self.codeRe, options: .regularExpression) != nil }
        let username = usernameField(fields) != nil
        var budget = 40_000
        var captcha = false
        AX.walk(page, budget: &budget) { element, _ in
            let words = (AX.string(element, "AXTitle") + AX.string(element, "AXDescription")).lowercased()
            if words.contains("recaptcha") || words.contains("hcaptcha") || words.contains("not a robot") { captcha = true }
            return !captcha
        }
        var text = AX.string(page, "AXTitle")
        var textBudget = 40_000
        AX.walk(page, budget: &textBudget) { element, role in
            if role == "AXWebArea", !CFEqual(element, page) { return false }
            if role == "AXHeading" || role == "AXButton" {
                text += " " + AX.string(element, "AXTitle") + " " + AX.string(element, "AXDescription") + " " + AX.string(element, "AXValue")
            }
            return true
        }
        let hints = text.lowercased().range(of: Self.hintRe, options: .regularExpression) != nil
        return PageState(url: url.absoluteString, username: username, password: password, code: code, captcha: captcha, loginHints: hints)
    }

    /// A labelled box, or the plain box just before the only password box.
    private func usernameField(_ fields: [AX.Field]) -> AX.Field? {
        let plain = fields.filter { !$0.isSecure && $0.words.range(of: Self.codeRe, options: .regularExpression) == nil }
        if let named = plain.first(where: { $0.words.range(of: Self.userRe, options: .regularExpression) != nil && $0.words.range(of: "(search|filter|query)", options: .regularExpression) == nil }) {
            return named
        }
        guard let i = fields.firstIndex(where: \.isSecure), i > 0, !fields[i - 1].isSecure else { return nil }
        return fields[i - 1]
    }

    private func set(_ field: AXUIElement, _ value: String) throws {
        AXUIElementSetAttributeValue(field, "AXFocused" as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(field, "AXValue" as CFString, value as CFString) == .success else {
            throw BrowserError.failed("field refused the value")
        }
    }

    private func press(_ page: AXUIElement, after field: AXUIElement) {
        let title = { (b: AXUIElement) in AX.string(b, "AXTitle") + " " + AX.string(b, "AXDescription") }
        if let button = AX.buttons(page).first(where: { title($0).range(of: Self.goRe, options: .regularExpression) != nil && title($0).range(of: Self.notThisRe, options: .regularExpression) == nil }) {
            AXUIElementPerformAction(button, "AXPress" as CFString)
        } else {
            AXUIElementPerformAction(field, "AXConfirm" as CFString)
        }
    }

    private func checked(_ tab: String, expectedHost: String) throws -> AXUIElement {
        let page = try area(tab)
        guard let url = AX.url(page), hostKey(url) == expectedHost else { throw BrowserError.failed("page_moved") }
        return page
    }

    public func fillLogin(tab: String, expectedHost: String, username: String?, password: Secret?, submit: Bool) async throws {
        let page = try checked(tab, expectedHost: expectedHost)
        let fields = AX.fields(page)
        var last: AXUIElement?
        if let username {
            guard let field = usernameField(fields) else {
                throw BrowserError.failed("no_username_field")
            }
            try set(field.element, username)
            last = field.element
        }
        if let password {
            guard let field = fields.first(where: \.isSecure) else { throw BrowserError.failed("no_password_field") }
            try set(field.element, password.reveal())
            last = field.element
        }
        if submit, let last { press(page, after: last) }
    }

    public func fillCode(tab: String, expectedHost: String, code: Secret, submit: Bool) async throws {
        let page = try checked(tab, expectedHost: expectedHost)
        guard let field = AX.fields(page).first(where: { $0.words.range(of: Self.codeRe, options: .regularExpression) != nil }) else {
            throw BrowserError.failed("no_code_field")
        }
        try set(field.element, code.reveal())
        if submit { press(page, after: field.element) }
    }

    public func navigate(tab: String, url: URL) async throws {
        // Opening a link needs the browser's own controls, which aren't reachable from here.
        throw BrowserError.failed("email links aren't supported in Claude's browser yet")
    }
}
