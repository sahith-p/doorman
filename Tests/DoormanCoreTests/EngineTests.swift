import XCTest
@testable import DoormanCore

final class EngineTests: XCTestCase {
    private let adminURL = "https://app.example.com/login"
    private let host = "https://app.example.com"

    private func engine(_ browser: FakeBrowser?, settings: DoormanSettings = acmeSettings(), approver: FakeApprover = FakeApprover(),
                        passwords: FakePasswords = FakePasswords(), mail: FakeMail = FakeMail(), activity: ActivityLog = ActivityLog(), changed: Bool = false) -> SignInEngine {
        SignInEngine(settings: { changed ? .changedOutside : .usable(settings) }, approver: approver, passwords: passwords, mail: mail,
                     adapters: { browser.map { [$0] } ?? [] }, activity: activity, timing: fastTiming())
    }

    private func page(_ url: String? = nil, username: Bool = false, password: Bool = false, code: Bool = false, captcha: Bool = false, frame: Bool = false) -> PageState {
        PageState(url: url ?? adminURL, username: username, password: password, code: code, captcha: captcha,
                  frameLogin: frame)
    }

    func testPasswordOnlySiteNeedsNoCodeStep() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/home")])
        let approver = FakeApprover()
        let result = await engine(browser, approver: approver).signIn(SignInRequest(address: adminURL, reason: "deploy"))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.fills, ["login:a@example.com:pw"])
        XCTAssertEqual(browser.filledPasswords, ["hunter2-demo"])
        XCTAssertEqual(approver.log.value.count, 1)
        XCTAssertEqual(approver.log.value[0].agentReason, "deploy")
        XCTAssertEqual(approver.log.value[0].app, "Acme Production")
    }

    func testAResultNeverCarriesASecret() async throws {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page(code: true), page("\(host)/home")])
        let result = await engine(browser, passwords: FakePasswords(password: "hunter2-demo", code: "424242")).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains("hunter2-demo"))
        XCTAssertFalse(json.contains("424242"))
        XCTAssertEqual(browser.filledCodes, ["424242"])
    }

    func testAuthenticatorCodeOnlyWhenTheSiteAsks() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page(code: true), page("\(host)/home")])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.fills, ["login:a@example.com:pw", "code"])
    }

    func testTwoStepFormGetsLoginThenPassword() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true), page(password: true), page("\(host)/home")])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.fills, ["login:a@example.com:nopw", "login:-:pw"])
    }

    func testAPageWithNoBoxesHasNothingToFill() async {
        let browser = FakeBrowser(url: "\(host)/home", pages: [page("\(host)/home")])
        let result = await engine(browser).signIn(SignInRequest(address: "\(host)/home"))
        XCTAssertEqual(result.status, .nothingToFill)
        XCTAssertEqual(result.reason, Reason.nothingToFill)
        XCTAssertEqual(browser.fills, [])
    }

    func testWrongPasswordIsNotRetried() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.reason, Reason.passwordRejected)
        XCTAssertEqual(browser.filledPasswords.count, 1, "a refused password must never be tried twice")
    }

    func testWrongCodeIsNotRetried() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page(code: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.codeRejected)
        XCTAssertEqual(browser.filledCodes.count, 1)
    }

    func testDenyTypesNothing() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser, approver: FakeApprover(decision: .denied)).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(browser.fills, [])
    }

    func testUnansweredPromptTypesNothing() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser, approver: FakeApprover(decision: .timedOut)).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .timeout)
        XCTAssertEqual(browser.fills, [])
    }

    func testAPageThatLeftTheSiteGetsNothing() async {
        let browser = FakeBrowser(url: adminURL, pages: [page("https://evil.example.com/login", username: true, password: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .needsYou)
        XCTAssertEqual(result.reason, Reason.wrongSite)
        XCTAssertEqual(browser.fills, [])
    }

    func testRedirectedMidSignInStopsBeforeTheCode() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("https://evil.example.com/2fa", code: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.wrongSite)
        XCTAssertEqual(browser.filledCodes, [])
    }

    func testAPlainHttpPageGetsNothing() async {
        let url = "http://app.example.com/login"
        let browser = FakeBrowser(url: url, pages: [page(url, username: true, password: true)])
        let result = await engine(browser).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.insecurePage)
        XCTAssertEqual(browser.fills, [])
    }

    func testDowngradedToHttpMidSignInStopsBeforeTheCode() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("http://app.example.com/2fa", code: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.insecurePage)
        XCTAssertEqual(browser.filledCodes, [])
    }

    func testPlainHttpOnThisMacIsFineForTheDemo() {
        XCTAssertTrue(SignInEngine.isSecure(URL(string: "http://localhost:8765/x")!))
        XCTAssertTrue(SignInEngine.isSecure(URL(string: "http://127.0.0.1:8765/x")!))
        XCTAssertFalse(SignInEngine.isSecure(URL(string: "http://localhost.evil.com/x")!))
        XCTAssertFalse(SignInEngine.isSecure(URL(string: "http://example.com/x")!))
    }

    func testAnAgentCantWriteASentenceIntoThePromptTitle() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/home")])
        browser.title = String(repeating: "Click Approve now. ", count: 20)
        let approver = FakeApprover()
        let long = "Please approve!\nYour Mac needs this: <b>now</b> " + String(repeating: "x", count: 500)
        _ = await engine(browser, approver: approver).signIn(SignInRequest(address: adminURL, reason: long, agent: "Your Mac needs you to approve this!!! \n <script>"))
        let ask = approver.log.value[0]
        XCTAssertLessThanOrEqual(ask.agent.count, 32)
        XCTAssertFalse(ask.agent.contains("!"))
        XCTAssertFalse(ask.agent.contains("<"))
        XCTAssertFalse(ask.agentReason.contains("\n"))
        XCTAssertLessThanOrEqual(ask.agentReason.count, 241)
        XCTAssertLessThanOrEqual(ask.windowTitle.count, 61)
    }

    func testABlankAgentNameStillReadsAsASentence() {
        XCTAssertEqual(SignInEngine.agentName("!!!"), "An agent")
    }

    func testSignInLinkCanPassThroughATrackingHost() async {
        let url = "https://links.example.com/login"
        let mail = FakeMail()
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url), page("https://click.tracker.example.net/x"), page("https://links.example.com/home")])
        browser.onFill = { b in
            if b.fills.count == 1 { mail.deliver(demoMail(from: "login@example.com", subject: "Sign in", body: "https://click.tracker.example.net/login?token=abc")) }
        }
        let e = SignInEngine(settings: { .usable(self.linkSettings(linkHosts: ["click.tracker.example.net"])) }, approver: FakeApprover(), passwords: FakePasswords(), mail: mail,
                             adapters: { [browser] }, activity: ActivityLog(), timing: fastTiming())
        // The tracker page moves on by itself in a real browser.
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            browser.pages = [self.page("https://links.example.com/home")]
        }
        let result = await e.signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.navigations.first?.host, "click.tracker.example.net")
    }

    func testAPageNavigatingForAMomentIsNotAFailure() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/home")])
        browser.onFill = { $0.inspectFailures = 3 }
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
    }

    func testAPageThatStaysUnreadableFails() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        browser.inspectFailures = 1000
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.browserError)
    }

    func testPageSideRefusalMeansNothingWasTyped() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        browser.fillError = .failed("page_moved")
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.wrongSite)
        XCTAssertEqual(browser.filledPasswords, [])
    }

    func testTheAgentDecidesWhatsALoginBoxNotWordsOnThePage() async {
        let url = "\(host)/settings"
        let browser = FakeBrowser(url: url, pages: [page(url, username: true)])
        let approver = FakeApprover()
        _ = await engine(browser, approver: approver).signIn(SignInRequest(address: url))
        XCTAssertEqual(approver.log.value.count, 1, "you still approve it")
        XCTAssertEqual(browser.fills.count, 1)
    }

    func testABoxBehindAPasswordIsntTreatedAsALoginName() async {
        // A search or email box on the page you land on, after the password has gone in.
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/home", username: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.fills.count, 1, "only the login itself")
    }

    func testACodeBoxAfterAPasswordCountsEvenWithNoHints() async {
        let url = "\(host)/step2"
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page(url, code: true), page("\(host)/home")])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.filledCodes, ["424242"])
    }

    func testAFormInAnEmbeddedFrameIsHandedBack() async {
        let url = "\(host)/welcome"
        let browser = FakeBrowser(url: url, pages: [page(url, frame: true)])
        let result = await engine(browser).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .needsYou)
        XCTAssertEqual(result.reason, Reason.noForm)
        XCTAssertEqual(browser.fills, [])
    }

    func testThePromptShowsWhichApplePasswordsEntry() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/home")])
        let approver = FakeApprover()
        _ = await engine(browser, approver: approver).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(approver.log.value[0].accounts[0].passwordSite, "app.example.com")
    }

    func testCaptchaIsHandedBack() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true, captcha: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .needsYou)
        XCTAssertEqual(result.reason, Reason.captcha)
        XCTAssertEqual(browser.fills, [])
    }

    func testPausedTypesNothing() async {
        var s = acmeSettings()
        s.paused = true
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser, settings: s).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .paused)
        XCTAssertEqual(browser.fills, [])
    }

    func testSettingsChangedOutsideStopsEverything() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser, changed: true).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.settingsChanged)
        XCTAssertEqual(browser.fills, [])
    }

    func testNoBrowserAndNoWindowAreDifferentAnswers() async {
        let none = await engine(nil).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(none.reason, Reason.noBrowser)
        let other = FakeBrowser(url: "https://elsewhere.example.com/", pages: [page()])
        let nowindow = await engine(other).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(nowindow.reason, Reason.noWindow)
    }

    func testNotConnectedToApplePasswordsSaysSo() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser, passwords: FakePasswords(error: .notConnected)).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.appleNotPaired)
        XCTAssertEqual(browser.fills, [])
    }

    func testPromptAsksWhichWhenSeveralAccountsMatch() async {
        let url = "https://staging.example.net/technician"
        let browser = FakeBrowser(url: url, pages: [page(url, username: true, password: true), page("https://staging.example.net/technician/home")])
        let approver = FakeApprover()
        let result = await engine(browser, approver: approver).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(approver.log.value.count, 1, "two test accounts match, so even no-tap accounts go through the prompt")
        XCTAssertEqual(approver.log.value[0].accounts.count, 2)
    }

    func testNoPopupAccountSkipsThePrompt() async {
        let url = "https://staging.example.net/"
        let browser = FakeBrowser(url: url, pages: [page(url, username: true, password: true), page("https://staging.example.net/home")])
        let approver = FakeApprover()
        let result = await engine(browser, approver: approver).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(approver.log.value.count, 0)
    }

    func testEmailCodeFromTheRightSender() async {
        let url = "https://app.example.com/admin"
        let mail = FakeMail()
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true), page("https://app.example.com/admin/home")])
        browser.onFill = { b in
            if b.fills.count == 1 { mail.deliver(demoMail(from: "no-reply@example.com", subject: "Your sign-in code", body: "Your code is 123456.")) }
        }
        let result = await engine(browser, mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.filledCodes, ["123456"])
    }

    func testEmailFromAnyoneElseIsIgnored() async {
        let url = "https://app.example.com/admin"
        let mail = FakeMail()
        mail.deliver(demoMail(from: "attacker@evil.example.com", subject: "Your sign-in code", body: "Your code is 666666."))
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true)])
        let result = await engine(browser, mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.mailNotFound)
        XCTAssertEqual(browser.filledCodes, [])
    }

    func testAnySenderInTheListCounts() async {
        let url = "https://app.example.com/admin"
        let mail = FakeMail()
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true), page("https://app.example.com/admin/home")])
        browser.onFill = { b in
            if b.fills.count == 1 { mail.deliver(demoMail(from: "login@mail.example.org", subject: "Your Acme Admin Code", body: "Your code is 246810.")) }
        }
        let result = await engine(browser, mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.filledCodes, ["246810"])
    }

    func testAnUnverifiedEmailIsToldApartFromNoEmail() async {
        let url = "https://app.example.com/admin"
        let mail = FakeMail()
        mail.deliver("From: <no-reply@example.com>\r\nAuthentication-Results: mx.test; spf=pass; dkim=none\r\nSubject: Code\r\n\r\nYour code is 111222.\r\n")
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true)])
        let result = await engine(browser, mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.mailNotVerified)
        XCTAssertEqual(browser.filledCodes, [])
    }

    func testAnEmailWithNoCodeIsToldApartFromNoEmail() async {
        let url = "https://app.example.com/admin"
        let mail = FakeMail()
        mail.deliver(demoMail(from: "no-reply@example.com", subject: "Welcome", body: "Thanks for joining."))
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true)])
        let result = await engine(browser, mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.mailNoCode)
    }

    func testAnOldEmailIsNotUsed() async {
        let url = "https://app.example.com/admin"
        let mail = FakeMail()
        mail.deliver(demoMail(from: "no-reply@example.com", subject: "Your code", body: "Your code is 111111.", date: Date().addingTimeInterval(-3600)))
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true)])
        let result = await engine(browser, mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.mailNotFound)
        XCTAssertEqual(browser.filledCodes, [])
    }

    func testNoTapWhenThereIsNothingToFill() async {
        let browser = FakeBrowser(url: "\(host)/home", pages: [page("\(host)/home")])
        let approver = FakeApprover()
        let result = await engine(browser, approver: approver).signIn(SignInRequest(address: "\(host)/home"))
        XCTAssertEqual(result.reason, Reason.nothingToFill)
        XCTAssertEqual(approver.log.value.count, 0, "nothing to approve")
    }

    func testNoMailboxAsksYouForTheCodeInstead() async {
        let url = "https://app.example.com/admin"
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true), page("https://app.example.com/admin/home")])
        let result = await engine(browser, approver: FakeApprover(typedCode: "135790"), mail: FakeMail(error: .notConnected)).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.filledCodes, ["135790"])
    }

    func testABrowserPreferenceOnlyLooksThere() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true)])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL, browser: "claude"))
        XCTAssertEqual(result.reason, Reason.noWindow)
        XCTAssertEqual(browser.fills, [])
    }

    func testNoMailboxSaysSo() async {
        let url = "https://app.example.com/admin"
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url, code: true)])
        let result = await engine(browser, mail: FakeMail(error: .notConnected)).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.mailUnavailable)
    }

    private func linkSettings(linkHosts: [String] = []) -> DoormanSettings {
        let role = Role(name: "User", path: "/", signIn: .emailLink, codeIfAsked: .none, mailSender: "@example.com", linkHosts: linkHosts)
        return DoormanSettings(apps: [AppProfile(name: "Links", host: "links.example.com", roles: [role], accounts: [
            Account(name: "Me", roleID: role.id, login: "me@example.com"),
        ])])
    }

    func testEmailLinkOpensInTheSameTab() async {
        let url = "https://links.example.com/login"
        let mail = FakeMail()
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url), page("https://links.example.com/home")])
        browser.onFill = { b in
            if b.fills.count == 1 { mail.deliver(demoMail(from: "login@example.com", subject: "Sign in", body: "Sign in here: https://links.example.com/magic?token=abc")) }
        }
        let result = await engine(browser, settings: linkSettings(), mail: mail).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.navigations.map(\.absoluteString), ["https://links.example.com/magic?token=abc"])
    }

    func testEmailLinkToAnotherSiteIsNotOpened() async {
        let url = "https://links.example.com/login"
        let mail = FakeMail()
        let browser = FakeBrowser(url: url, pages: [page(url, username: true), page(url)])
        browser.onFill = { b in
            if b.fills.count == 1 { mail.deliver(demoMail(from: "login@example.com", subject: "Sign in", body: "Sign in: https://evil.example.org/magic?token=abc")) }
        }
        let result = await engine(browser, settings: linkSettings(), mail: mail).signIn(SignInRequest(address: url))
        // The email arrived and is genuine, but holds no link Doorman is allowed to open.
        XCTAssertEqual(result.reason, Reason.mailNoCode)
        XCTAssertEqual(browser.navigations, [])
    }

    func testAskMeTakesACodeYouTypedIntoDoorman() async {
        var s = acmeSettings()
        for i in s.apps[0].roles.indices { s.apps[0].roles[i].codeIfAsked = .askMe }
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page(code: true), page("\(host)/home")])
        let result = await engine(browser, settings: s, approver: FakeApprover(typedCode: "987654")).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.filledCodes, ["987654"])
    }

    func testCodeIfAskedNoneHandsBack() async {
        var s = acmeSettings()
        for i in s.apps[0].roles.indices { s.apps[0].roles[i].codeIfAsked = .none }
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page(code: true)])
        let result = await engine(browser, settings: s).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.reason, Reason.codeRequested)
    }

    func testWhereThePageLandedIsForTheAgentToJudge() async {
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/login")])
        let result = await engine(browser).signIn(SignInRequest(address: adminURL))
        XCTAssertEqual(result.status, .filled, "it reports what it did, and doesn't guess from the address")
        XCTAssertTrue(result.message.contains("Look at the page"))
    }

    func testActivityRecordsTheAttemptWithoutSecrets() async throws {
        let activity = ActivityLog()
        let browser = FakeBrowser(url: adminURL, pages: [page(username: true, password: true), page("\(host)/home")])
        _ = await engine(browser, activity: activity).signIn(SignInRequest(address: adminURL, agent: "claude-code"))
        let entry = try XCTUnwrap(activity.recent().first)
        XCTAssertEqual(entry.status, .filled)
        XCTAssertEqual(entry.agent, "claude-code")
        XCTAssertEqual(entry.account, "Prod admin")
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        XCTAssertFalse(json.contains("hunter2"))
    }
}

final class MailTests: XCTestCase {
    private func parse(_ s: String) -> ParsedMail { MailParser.parse(Data(s.utf8)) }

    func testCodeWithALabel() {
        XCTAssertEqual(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Hi", body: "Your verification code is 482913. It expires soon."))), "482913")
    }

    func testCodeInTheSubject() {
        XCTAssertEqual(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "271828 is your sign-in code", body: "Thanks"))), "271828")
    }

    func testSpacedCode() {
        XCTAssertEqual(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Code", body: "Your code: 123 456"))), "123456")
    }

    func testCodeAloneOnALine() {
        XCTAssertEqual(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Sign in", body: "Enter this:\n\n  730142\n\nThanks"))), "730142")
    }

    func testOrderNumberAndYearAreNotCodes() {
        XCTAssertNil(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Receipt", body: "Order 99887766 shipped in 2026. Call 5551234."))))
        XCTAssertNil(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Hello", body: "Copyright\n2026\nAll rights reserved"))))
    }

    func testLabelBeatsAnEarlierNumber() {
        XCTAssertEqual(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Ticket 55555", body: "Your code is 112233"))), "112233")
    }

    func testAlphanumericCode() {
        XCTAssertEqual(MailExtract.code(in: parse(demoMail(from: "a@x.com", subject: "Verification", body: "Use this:\nAB12-CD34\n"))), "AB12-CD34")
    }

    func testMultipartBase64AndQuotedPrintable() {
        let html = Data("<p>Your code is <b>654321</b></p>".utf8).base64EncodedString()
        let raw = "From: Sender <s@x.com>\r\nSubject: =?UTF-8?B?U2lnbiBpbg==?=\r\nContent-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n--b1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nSee the =\r\nHTML part=3D.\r\n--b1\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(html)\r\n--b1--\r\n"
        let mail = parse(raw)
        XCTAssertEqual(mail.subject, "Sign in")
        XCTAssertEqual(mail.from, "s@x.com")
        XCTAssertTrue(mail.text.contains("See the HTML part="))
        XCTAssertEqual(MailExtract.code(in: mail), "654321")
    }

    func testSenderMatching() {
        // (see testForgedSenders for what this deliberately refuses)
        let mail = parse(demoMail(from: "no-reply@example.com", subject: "s", body: "b"))
        XCTAssertTrue(MailExtract.senderMatches(mail, expected: "no-reply@example.com"))
        XCTAssertTrue(MailExtract.senderMatches(mail, expected: "example.com"))
        XCTAssertTrue(MailExtract.senderMatches(mail, expected: "@example.com"))
        XCTAssertFalse(MailExtract.senderMatches(mail, expected: "other@example.com"))
        XCTAssertFalse(MailExtract.senderMatches(mail, expected: "ample.com"))
        XCTAssertFalse(MailExtract.senderMatches(parse(demoMail(from: "x@notexample.com", subject: "s", body: "b")), expected: "example.com"))
    }

    func testFailedAuthenticationDoesNotCount() {
        let raw = "From: <no-reply@example.com>\r\nAuthentication-Results: mx.google.com; dmarc=fail (p=NONE)\r\nSubject: s\r\n\r\nb\r\n"
        XCTAssertTrue(MailExtract.fromMatches(parse(raw), expected: "no-reply@example.com"))
        XCTAssertFalse(MailExtract.senderMatches(parse(raw), expected: "no-reply@example.com"))
    }

    private func forged(from: String, auth: String) -> ParsedMail {
        parse("From: \(from)\r\nAuthentication-Results: \(auth)\r\nSubject: s\r\n\r\nb\r\n")
    }

    func testForgedSenders() {
        let want = "no-reply@x.com"
        let good = "mx.google.com; dkim=pass header.i=@x.com; spf=pass; dmarc=pass (p=REJECT) header.from=x.com"
        XCTAssertTrue(MailExtract.senderMatches(forged(from: "X <no-reply@x.com>", auth: good), expected: want))
        // An address hidden in a comment, while DMARC passes for the attacker's own domain.
        let attacker = "mx.google.com; dmarc=pass header.from=evil.com"
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "\"no-reply@x.com\" <me@evil.com> (<no-reply@x.com>)", auth: attacker), expected: want))
        // An encoded name that decodes to an address.
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "=?UTF-8?Q?=3Cno-reply=40x.com=3E?= <me@evil.com>", auth: attacker), expected: want))
        // Right From, but the server vouches for someone else, or only for SPF.
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "<no-reply@x.com>", auth: attacker), expected: want))
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "<no-reply@x.com>", auth: "mx.google.com; spf=pass smtp.mailfrom=x.com; dkim=none"), expected: want))
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "<no-reply@x.com>", auth: "mx.google.com; spf=fail; dkim=none"), expected: want))
        // No record at all.
        XCTAssertFalse(MailExtract.senderMatches(parse("From: <no-reply@x.com>\r\nSubject: s\r\n\r\nb\r\n"), expected: want))
        // Two From headers, or two addresses in one.
        XCTAssertFalse(MailExtract.senderMatches(parse("From: <no-reply@x.com>\r\nFrom: <me@evil.com>\r\nAuthentication-Results: \(good)\r\n\r\nb\r\n"), expected: want))
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "<no-reply@x.com>, <me@evil.com>", auth: good), expected: want))
    }

    func testASignatureFromTheSameOrganizationCounts() {
        // Staging's mail: From a subdomain, which DMARC treats as the same organization.
        let want = "login@staging.example.org"
        XCTAssertTrue(MailExtract.senderMatches(forged(from: "<\(want)>", auth: "mx.google.com; dkim=pass header.i=@example.org; dmarc=none"), expected: want))
        XCTAssertTrue(MailExtract.senderMatches(forged(from: "<\(want)>", auth: "mx.google.com; dkim=pass header.i=@staging.example.org"), expected: want))
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "<\(want)>", auth: "mx.google.com; dkim=pass header.i=@com"), expected: want), "a bare top-level domain isn't an organization")
        XCTAssertFalse(MailExtract.senderMatches(forged(from: "<\(want)>", auth: "mx.google.com; dkim=pass header.i=@notexample.org"), expected: want))
    }

    func testOnlyYourOwnServersAuthResultCounts() {
        // Your server's header comes first. The attacker's own "pass" further down means nothing.
        let raw = "From: <no-reply@x.com>\r\nAuthentication-Results: mx.google.com; dmarc=fail header.from=x.com\r\nAuthentication-Results: evil; dmarc=pass header.from=x.com\r\n\r\nb\r\n"
        XCTAssertFalse(MailExtract.senderMatches(parse(raw), expected: "no-reply@x.com"))
    }

    func testAddressParsing() {
        XCTAssertEqual(MailParser.address(from: "\"Doe, Jane\" <Jane@X.com>"), "jane@x.com")
        XCTAssertEqual(MailParser.address(from: "jane@x.com (Jane)"), "jane@x.com")
        XCTAssertEqual(MailParser.address(from: "a@b@c.com"), "")
        XCTAssertEqual(MailParser.address(from: "<a@x.com> <b@x.com>"), "")
        XCTAssertEqual(MailParser.address(from: "not an address"), "")
    }

    func testSiteMatching() {
        XCTAssertTrue(Approval.siteMatches(site: "app.example.com", host: "app.example.com"))
        XCTAssertTrue(Approval.siteMatches(site: "example.com", host: "app.example.com"))
        XCTAssertTrue(Approval.siteMatches(site: "app.example.com", host: "example.com:8443"))
        XCTAssertFalse(Approval.siteMatches(site: "bank.com", host: "app.example.com"))
        XCTAssertFalse(Approval.siteMatches(site: "ample.com", host: "example.com"))
    }

    func testLinkMustBeOnAnAllowedHost() {
        let mail = parse(demoMail(from: "a@x.com", subject: "s", body: "Bad https://evil.example.org/login?token=1 Good https://app.example.com/login?token=2 Help https://app.example.com/help"))
        XCTAssertEqual(MailExtract.link(in: mail, allowedHosts: ["app.example.com"])?.absoluteString, "https://app.example.com/login?token=2")
        XCTAssertNil(MailExtract.link(in: mail, allowedHosts: ["other.example.com"]))
    }

    func testLinkWithAnHttpSchemeIsRefusedExceptOnLocalhost() {
        let mail = parse(demoMail(from: "a@x.com", subject: "s", body: "http://app.example.com/login?token=2"))
        XCTAssertNil(MailExtract.link(in: mail, allowedHosts: ["app.example.com"]))
        let local = parse(demoMail(from: "a@x.com", subject: "s", body: "http://localhost:8765/magic?token=2"))
        XCTAssertNotNil(MailExtract.link(in: local, allowedHosts: ["localhost:8765"]))
    }

    func testLinkFromAnHtmlHrefWithEntities() {
        let html = "<a href=\"https://app.example.com/verify?a=1&amp;token=abc\">Sign in</a>"
        let raw = "From: <a@x.com>\r\nContent-Type: text/html\r\n\r\n\(html)\r\n"
        XCTAssertEqual(MailExtract.link(in: parse(raw), allowedHosts: ["app.example.com"])?.absoluteString, "https://app.example.com/verify?a=1&token=abc")
    }
}

/// Sites you haven't added, using Apple Passwords.
final class UnaddedSiteTests: XCTestCase {
    private struct Passwords: PasswordSource {
        var logins: [String] = ["me@example.com"]
        var error: PasswordSourceError? = nil
        var asked = Box<[String]>([])
        func savedLogins(site: String) async throws -> SavedLogins {
            asked.value.append(site)
            if let error { throw error }
            return SavedLogins(names: logins)
        }
        func credential(for account: Account, host: String) async throws -> Credential {
            if case let .applePasswords(site) = account.credential, site == "shop.example.org" {
                return Credential(username: account.login, password: Secret("saved-password"))
            }
            throw PasswordSourceError.notFound
        }
        func authenticatorCode(for account: Account, url: URL) async throws -> Secret? { nil }
    }

    private let url = "https://shop.example.org/login"

    private func page(_ address: String, form: Bool = true) -> PageState {
        PageState(url: address, username: form, password: form)
    }

    private func engine(_ browser: FakeBrowser, passwords: Passwords = Passwords(), approver: FakeApprover = FakeApprover(), settings: DoormanSettings = DoormanSettings()) -> SignInEngine {
        SignInEngine(settings: { .usable(settings) }, approver: approver, passwords: passwords, mail: FakeMail(), adapters: { [browser] }, activity: ActivityLog(), timing: fastTiming())
    }

    func testASavedLoginWorksWithoutAddingTheSite() async {
        let browser = FakeBrowser(url: url, pages: [page(url), page("https://shop.example.org/home", form: false)])
        let approver = FakeApprover()
        let passwords = Passwords()
        let result = await engine(browser, passwords: passwords, approver: approver).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(browser.filledPasswords, ["saved-password"])
        XCTAssertEqual(passwords.asked.value, ["shop.example.org"])
        XCTAssertEqual(approver.log.value.count, 1, "it asked first")
        XCTAssertEqual(approver.log.value[0].accounts[0].passwordSite, "shop.example.org")
        XCTAssertEqual(approver.log.value[0].roleWarning, "You haven't added this site")
    }

    func testDenyingFillsNothing() async {
        let browser = FakeBrowser(url: url, pages: [page(url)])
        let result = await engine(browser, approver: FakeApprover(decision: .denied)).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(browser.fills, [])
    }

    func testNoSavedLoginAsksNothing() async {
        let browser = FakeBrowser(url: url, pages: [page(url)])
        let approver = FakeApprover()
        let result = await engine(browser, passwords: Passwords(logins: []), approver: approver).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.noApp)
        XCTAssertEqual(approver.log.value.count, 0)
    }

    func testSeveralLoginsLetYouPick() async {
        let browser = FakeBrowser(url: url, pages: [page(url)])
        let approver = FakeApprover(decision: .denied)
        _ = await engine(browser, passwords: Passwords(logins: ["a@x.com", "b@x.com"]), approver: approver).signIn(SignInRequest(address: url))
        XCTAssertEqual(approver.log.value[0].accounts.map(\.login), ["a@x.com", "b@x.com"])
    }

    func testTurningItOffStopsTheLookup() async {
        var settings = DoormanSettings()
        settings.allowUnaddedSites = false
        let browser = FakeBrowser(url: url, pages: [page(url)])
        let passwords = Passwords()
        let result = await engine(browser, passwords: passwords, settings: settings).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.noApp)
        XCTAssertEqual(passwords.asked.value, [], "not even a lookup")
    }

    func testASiteOnTheNeverListIsLeftAlone() async {
        var settings = DoormanSettings()
        settings.neverSites = "mybank.com, example.org"
        let browser = FakeBrowser(url: url, pages: [page(url)])
        let passwords = Passwords()
        let result = await engine(browser, passwords: passwords, settings: settings).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.noApp)
        XCTAssertEqual(passwords.asked.value, [], "a domain covers its subdomains")
    }

    func testNeverListMatching() {
        var s = DoormanSettings()
        s.neverSites = "mybank.com\nhttps://broker.com/login"
        XCTAssertTrue(s.isNeverSite("mybank.com"))
        XCTAssertTrue(s.isNeverSite("www.mybank.com:443"))
        XCTAssertTrue(s.isNeverSite("broker.com"))
        XCTAssertFalse(s.isNeverSite("notmybank.com"))
    }

    func testPlainHttpNeverGetsASavedPassword() async {
        let http = "http://shop.example.org/login"
        let browser = FakeBrowser(url: http, pages: [page(http)])
        let passwords = Passwords()
        let result = await engine(browser, passwords: passwords).signIn(SignInRequest(address: http))
        XCTAssertEqual(result.reason, Reason.insecurePage)
        XCTAssertEqual(passwords.asked.value, [])
    }

    func testAPageThatMovedGetsNothing() async {
        let browser = FakeBrowser(url: url, pages: [page(url), page("https://evil.example.com/login")])
        browser.pages = [page("https://evil.example.com/login")]
        browser.tabURL = url
        let result = await engine(browser).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.wrongSite)
        XCTAssertEqual(browser.fills, [])
    }

    func testAgentsCantProbeHundredsOfSites() async {
        let e = SignInEngine(settings: { .usable(DoormanSettings()) }, approver: FakeApprover(decision: .denied), passwords: Passwords(logins: []), mail: FakeMail(),
                             adapters: { [FakeBrowser(url: "https://a.example.org/login", pages: [PageState(url: "https://a.example.org/login", username: true, password: true)])] },
                             activity: ActivityLog(), timing: fastTiming())
        var last = SignInResult(status: .failed)
        for _ in 0..<11 { last = await e.signIn(SignInRequest(address: "https://a.example.org/login")) }
        XCTAssertEqual(last.reason, Reason.tooManyLookups)
    }

    func testNotConnectedSaysSo() async {
        let browser = FakeBrowser(url: url, pages: [page(url)])
        let result = await engine(browser, passwords: Passwords(error: .notConnected)).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.reason, Reason.appleNotPaired)
    }

    func testAnAddedAppUsesItsOwnAccountNotWhatALookupFinds() async {
        let role = Role(name: "User", path: "/", signIn: .password)
        let added = DoormanSettings(apps: [AppProfile(name: "Shop", host: "shop.example.org", roles: [role], accounts: [
            Account(name: "Me", roleID: role.id, login: "me@example.com", credential: .applePasswords(site: "shop.example.org")),
        ])])
        let browser = FakeBrowser(url: url, pages: [page(url), page("https://shop.example.org/home", form: false)])
        // Apple is only asked whether it will want Touch ID. Its answer doesn't choose the login.
        let passwords = Passwords(logins: ["someone-else@example.com"])
        let approver = FakeApprover()
        let result = await engine(browser, passwords: passwords, approver: approver, settings: added).signIn(SignInRequest(address: url))
        XCTAssertEqual(result.app, "Shop")
        XCTAssertEqual(result.account, "Me")
        XCTAssertEqual(approver.log.value[0].accounts.map(\.login), ["me@example.com"])
        XCTAssertEqual(browser.fills, ["login:me@example.com:pw"])
    }
}

final class ExampleTests: XCTestCase {
    func testTheExampleImportsAndIsValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try JSONDecoder().decode(DoormanSettings.self, from: Data(contentsOf: root.appendingPathComponent("examples/acme.json")))
        XCTAssertEqual(settings.apps.map(\.name), ["Acme Production", "Acme Staging"])
        XCTAssertEqual(SettingsValidator.problems(settings), [])
        guard case let .accounts(app, role, _) = Resolver.resolve(address: "https://app.acme.example/admin/users", settings: settings) else { return XCTFail("expected accounts") }
        XCTAssertEqual(app.name, "Acme Production")
        XCTAssertEqual(role.mailSenders, ["no-reply@acme.example", "login@mail.acme.example"])
    }
}
