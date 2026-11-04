import XCTest
@testable import DoormanCore

final class ResolverTests: XCTestCase {
    func testHostPicksTheAppAndLongestPathPicksTheRole() {
        guard case let .accounts(app, role, accounts) = Resolver.resolve(address: "https://staging.example.net/admin/organizations/66", settings: acmeSettings()) else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(app.name, "Acme Staging")
        XCTAssertEqual(role.name, "Superadmin")
        XCTAssertEqual(accounts.map(\.name), ["Staging superadmin"])
    }

    func testSamePathOnProdIsAProdAccount() {
        guard case let .accounts(app, _, accounts) = Resolver.resolve(address: "https://app.example.com/admin", settings: acmeSettings()) else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(app.name, "Acme Production")
        XCTAssertEqual(accounts.map(\.name), ["Prod superadmin"])
    }

    func testPathPrefixNeedsAWholeSegment() {
        // /administrator is not /admin. It falls through to the catch-all role.
        guard case let .accounts(_, role, _) = Resolver.resolve(address: "https://app.example.com/administrator", settings: acmeSettings()) else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(role.name, "Admin")
    }

    func testRootFallsToCatchAll() {
        guard case let .accounts(_, role, _) = Resolver.resolve(address: "https://app.example.com/", settings: acmeSettings()) else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(role.name, "Admin")
    }

    func testUnknownHostIsRefused() {
        XCTAssertEqual(Resolver.resolve(address: "https://evil.example.com/admin", settings: acmeSettings()), .noApp(host: "evil.example.com"))
    }

    func testLookalikeHostIsRefused() {
        XCTAssertEqual(Resolver.resolve(address: "https://app.example.com.evil.com/admin", settings: acmeSettings()), .noApp(host: "app.example.com.evil.com"))
    }

    func testPortIsPartOfTheHost() {
        XCTAssertEqual(Resolver.resolve(address: "https://app.example.com:8443/admin", settings: acmeSettings()), .noApp(host: "app.example.com:8443"))
    }

    func testNonWebAddressIsInvalid() {
        XCTAssertEqual(Resolver.resolve(address: "file:///etc/passwd", settings: acmeSettings()), .invalidAddress)
        XCTAssertEqual(Resolver.resolve(address: "not a url", settings: acmeSettings()), .invalidAddress)
    }

    func testSeveralAccountsAreAllReturned() {
        guard case let .accounts(_, _, accounts) = Resolver.resolve(address: "https://staging.example.net/technician", settings: acmeSettings()) else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(accounts.count, 2)
    }

    func testAgentCanAskForARoleButNotAnApp() {
        guard case let .accounts(app, role, _) = Resolver.resolve(address: "https://staging.example.net/", settings: acmeSettings(), roleName: "technician") else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(role.name, "Technician")
        XCTAssertEqual(app.name, "Acme Staging")
    }

    func testUnknownRoleNameIsReported() {
        if case .roleNotFound = Resolver.resolve(address: "https://app.example.com/", settings: acmeSettings(), roleName: "owner") { return }
        XCTFail("expected roleNotFound")
    }

    func testNormalizers() {
        XCTAssertEqual(normalizeHost(" HTTPS://App.Example.com:8443/x "), "app.example.com:8443")
        XCTAssertEqual(normalizePath("admin/"), "/admin")
        XCTAssertEqual(normalizePath(""), "/")
    }

    func testDescribeTellsYouWhatWillHappen() {
        let text = Resolver.describe(Resolver.resolve(address: "https://app.example.com/admin", settings: acmeSettings()))
        XCTAssertEqual(text, "Acme Production, Superadmin: Prod superadmin. Asks you first.")
        let many = Resolver.describe(Resolver.resolve(address: "https://staging.example.net/technician", settings: acmeSettings()))
        XCTAssertTrue(many.contains("2 accounts match"))
    }

    func testSendersAreAList() {
        let role = Role(name: "r", path: "/", signIn: .emailCode, mailSender: " a@x.com, y.com  b@z.com ,")
        XCTAssertEqual(role.mailSenders, ["a@x.com", "y.com", "b@z.com"])
    }
}

final class ApprovalRuleTests: XCTestCase {
    func testEveryAccountAsksFirstUnlessYouTurnedThatOff() {
        XCTAssertTrue(Approval.asksFirst(account: Account(name: "a", roleID: UUID(), login: "x")), "asking is the default")
        XCTAssertFalse(Approval.asksFirst(account: Account(name: "a", roleID: UUID(), login: "x", approval: .noPopup)))
    }

    func testValidatorAcceptsTheAcmeSetup() {
        XCTAssertEqual(SettingsValidator.problems(acmeSettings()), [])
    }

    func testValidatorCatchesDuplicateHostsAndMissingSender() {
        var s = acmeSettings()
        s.apps.append(AppProfile(name: "Other", host: "https://app.example.com/"))
        s.apps[0].roles[0].mailSender = ""
        let problems = SettingsValidator.problems(s)
        XCTAssertTrue(problems.contains { $0.contains("app.example.com is in both") })
        XCTAssertTrue(problems.contains { $0.contains("enter who sends the email") })
    }

    func testAppsFromTheOldShapeJustNeedAddingAgain() throws {
        let old = #"{"apps":[{"id":"1B9D6BCD-BBFD-4B2D-9B5D-AB8DFBBD4BED","name":"Old","environments":[],"roles":[],"accounts":[]}],"paused":true,"mail":{"provider":"gmail","address":"","imapHost":"h","imapPort":1,"gmailClientID":"c"}}"#
        let settings = try JSONDecoder().decode(DoormanSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.apps, [])
        XCTAssertEqual(settings.mail.provider, .gmail, "the mailbox connection survives")
        XCTAssertTrue(settings.paused)
    }
}

final class SettingsStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("doorman-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testRoundTrip() throws {
        let store = SettingsStore(directory: tempDir(), keys: InMemorySigningKey())
        XCTAssertEqual(try store.load(), .empty)
        let s = acmeSettings()
        try store.save(s)
        guard case let .ok(loaded) = try store.load() else { return XCTFail("expected ok") }
        XCTAssertEqual(loaded.apps, s.apps)
    }

    func testEditingTheFileFromOutsideIsDetected() throws {
        let dir = tempDir()
        let store = SettingsStore(directory: dir, keys: InMemorySigningKey())
        try store.save(acmeSettings())
        let file = dir.appendingPathComponent("settings.json")
        // What an agent would try: quietly turn prod into a no-tap test environment.
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"isTest\" : false", with: "\"isTest\" : true")
        try text.write(to: file, atomically: true, encoding: .utf8)
        guard case .changedOutside = try store.load() else { return XCTFail("tamper not detected") }
    }

    func testDeletingTheSignatureIsDetected() throws {
        let dir = tempDir()
        let store = SettingsStore(directory: dir, keys: InMemorySigningKey())
        try store.save(acmeSettings())
        try FileManager.default.removeItem(at: dir.appendingPathComponent("settings.sig"))
        guard case .changedOutside = try store.load() else { return XCTFail("tamper not detected") }
    }

    func testDeletingTheSettingsIsDetected() throws {
        let dir = tempDir()
        let store = SettingsStore(directory: dir, keys: InMemorySigningKey())
        try store.save(acmeSettings())
        try FileManager.default.removeItem(at: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(try store.load(), .changedOutside(nil))
    }

    func testAnotherKeyDoesNotVerify() throws {
        let dir = tempDir()
        try SettingsStore(directory: dir, keys: InMemorySigningKey()).save(acmeSettings())
        guard case .changedOutside = try SettingsStore(directory: dir, keys: InMemorySigningKey()).load() else { return XCTFail("wrong key accepted") }
    }

    func testPuttingAnOldValidCopyBackIsDetected() throws {
        let dir = tempDir()
        let keys = InMemorySigningKey()
        let generations = InMemoryGenerationStore()
        let store = SettingsStore(directory: dir, keys: keys, generations: generations)
        var s = acmeSettings()
        try store.save(s)
        let fm = FileManager.default
        let file = dir.appendingPathComponent("settings.json"), sig = dir.appendingPathComponent("settings.sig")
        let oldFile = try Data(contentsOf: file), oldSig = try Data(contentsOf: sig)
        // You pause sign-ins, or remove a no-tap account.
        s.paused = true
        try store.save(s)
        guard case let .ok(loaded) = try store.load() else { return XCTFail("expected ok") }
        XCTAssertTrue(loaded.paused)
        // An agent puts the old file and its genuine signature back.
        try oldFile.write(to: file)
        try oldSig.write(to: sig)
        _ = fm
        guard case .changedOutside = try store.load() else { return XCTFail("replay not detected") }
    }

    func testFilesAreOwnerOnly() throws {
        let dir = tempDir()
        try SettingsStore(directory: dir, keys: InMemorySigningKey()).save(acmeSettings())
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("settings.json").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }
}

final class SecretTests: XCTestCase {
    func testASecretCantBePrintedByAccident() {
        let s = Secret("hunter2")
        XCTAssertFalse("\(s)".contains("hunter2"))
        XCTAssertFalse(String(describing: s).contains("hunter2"))
        XCTAssertFalse(String(reflecting: s).contains("hunter2"))
        var dumped = ""
        dump(s, to: &dumped)
        XCTAssertFalse(dumped.contains("hunter2"))
        let c = Credential(username: "u", password: s)
        XCTAssertFalse(String(reflecting: c).contains("hunter2"))
        XCTAssertEqual(s.reveal(), "hunter2")
    }
}
