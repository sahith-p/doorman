import XCTest
import CryptoKit
@testable import DoormanCore

final class BigUIntTests: XCTestCase {
    func testAgainstKnownValues() {
        let a = BigUInt(hex: "ffffffffffffffffffffffffffffffff")!
        XCTAssertEqual((a + BigUInt(1)).hex, "0100000000000000000000000000000000")
        XCTAssertEqual((a - a).isZero, true)
        XCTAssertEqual((a * a).hex, "fffffffffffffffffffffffffffffffe00000000000000000000000000000001")
        XCTAssertEqual((BigUInt(1000) % BigUInt(7)).hex, "06")
        XCTAssertEqual(BigUInt(2).power(BigUInt(10), modulus: BigUInt(1000)).hex, "18")
    }

    func testDivisionIdentityOverAWideRange() {
        // q * m + r == a, r < m, for shapes that hit Knuth D's correction branches.
        var seed: UInt64 = 0x1234_5678_9abc_def0
        func next() -> UInt32 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt32(truncatingIfNeeded: seed)
        }
        for round in 0..<300 {
            let mLimbs = 2 + round % 12
            let aLimbs = mLimbs + round % 12
            var m = (0..<mLimbs).map { _ in next() }
            var a = (0..<aLimbs).map { _ in next() }
            if round % 3 == 0 { m[mLimbs - 1] = 0x8000_0000; m[0] = 0 }
            if round % 5 == 0 { a[aLimbs - 1] = 0xffff_ffff; for i in 0..<aLimbs - 1 { a[i] = 0xffff_ffff } }
            let bigM = BigUInt(limbs: m), bigA = BigUInt(limbs: a)
            guard !bigM.isZero else { continue }
            let r = bigA % bigM
            XCTAssertLessThan(r, bigM)
            // a - r must be an exact multiple of m: a second mod gives zero.
            XCTAssertTrue(((bigA - r) % bigM).isZero, "round \(round)")
        }
    }

    func testBytesRoundTrip() {
        let bytes: [UInt8] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertEqual(BigUInt(bytes: bytes).bytes, Array(bytes.dropFirst(2)))
        XCTAssertEqual(BigUInt(bytes: bytes).padded(to: 11), bytes)
    }
}

private func bytes(_ hex: String) -> [UInt8] { SRPClient(useBase64: false, I: [1], a: BigUInt(1)).deserialize(hex)! }

/// The fixtures come from Node's BigInt and, when generated, from Apple's own client code. Passing them
/// is the closest thing to a real pairing that doesn't need a person to type a PIN.
final class SRPFixtureTests: XCTestCase {
    func testAppleClientAgreedWithTheFixture() {
        XCTAssertTrue(SRPFixture.appleVerified, "regenerate with Apple's background.js: node scripts/srp_fixture.mjs <path>")
        XCTAssertTrue(SRPFixture.rows.contains { $0.base64 }, "macOS asks for base64 mode, so the fixture has to cover it")
    }

    func testMatchesFixtures() throws {
        for row in SRPFixture.rows {
            let client = SRPClient(useBase64: row.base64, I: bytes(row.I), a: BigUInt(hex: row.a)!)
            XCTAssertEqual(client.A.hex, row.A, row.name)
            XCTAssertEqual(client.tid, row.base64 ? Data(bytes(row.I)).base64EncodedString() : "0x" + row.I, row.name)
            let proof = try client.proof(pin: row.pin, salt: bytes(row.salt), B: BigUInt(hex: row.B)!)
            XCTAssertEqual(proof.sessionKey, bytes(row.K), row.name)
            XCTAssertEqual(proof.M, bytes(row.M), row.name)
            XCTAssertEqual(proof.HAMK, bytes(row.HAMK), row.name)
        }
    }

    func testAWrongPINGivesADifferentProof() throws {
        let row = SRPFixture.rows[0]
        let client = SRPClient(useBase64: false, I: bytes(row.I), a: BigUInt(hex: row.a)!)
        let proof = try client.proof(pin: "999999", salt: bytes(row.salt), B: BigUInt(hex: row.B)!)
        XCTAssertNotEqual(proof.M, bytes(row.M))
    }

    func testRefusesAServerKeyOfZero() {
        let client = SRPClient(useBase64: false)
        XCTAssertThrowsError(try client.proof(pin: "1", salt: [1], B: BigUInt()))
        XCTAssertThrowsError(try client.proof(pin: "1", salt: [1], B: SRPGroup.N))
    }

    func testEncryptMatchesNode() throws {
        let session = AppleSession(tid: "0xabc", key: Data(bytes(SRPFixture.aesKey)), useBase64: false)
        let object = try JSONSerialization.jsonObject(with: Data(SRPFixture.aesPlain.utf8)) as! [String: Any]
        // Key order isn't fixed in Swift, so seal the exact bytes Node did and compare.
        _ = object
        let sealed = try AES.GCM.seal(Data(SRPFixture.aesPlain.utf8), using: SymmetricKey(data: Data(bytes(SRPFixture.aesKey))),
                                      nonce: AES.GCM.Nonce(data: Data(bytes(SRPFixture.aesIV))))
        let out = sealed.ciphertext + sealed.tag + Data(bytes(SRPFixture.aesIV))
        XCTAssertEqual(session.stringOf(out), SRPFixture.aesOut)
    }

    func testDecryptsWhatTheHelperWrites() throws {
        let session = AppleSession(tid: "0xabc", key: Data(bytes(SRPFixture.aesKey)), useBase64: false)
        let plain = try session.open(sdata: SRPFixture.replySDATA)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), SRPFixture.replyPlain)
    }

    func testTamperedCiphertextIsRefused() {
        let session = AppleSession(tid: "0xabc", key: Data(bytes(SRPFixture.aesKey)), useBase64: false)
        var tampered = SRPFixture.replySDATA
        tampered.removeLast()
        tampered.append(SRPFixture.replySDATA.last == "0" ? "1" : "0")
        XCTAssertThrowsError(try session.open(sdata: tampered))
    }
}

/// A stand-in for Apple's helper, doing the server side of the pairing.
private actor FakeHelper {
    let pin: String
    let useBase64: Bool
    let salt = SRPClient.randomBytes(16)
    private let b = BigUInt(bytes: SRPClient.randomBytes(32))
    private var A = BigUInt()
    private var tid = ""
    private var key: [UInt8] = []
    private var B = BigUInt()
    private var expectedM: [UInt8] = []
    private var hamk: [UInt8] = []
    var entries: [[String: Any]]
    var pinPopups = 0
    var deliver: (@Sendable (Data) async -> Void)?
    var passwordRequests: [[String: Any]] = []
    var knowsSession = true

    init(pin: String, useBase64: Bool, entries: [[String: Any]]) {
        self.pin = pin
        self.useBase64 = useBase64
        self.entries = entries
    }

    func connect(_ deliver: @escaping @Sendable (Data) async -> Void) { self.deliver = deliver }
    func forgetSession() { knowsSession = false }

    private var codec: SRPClient { SRPClient(useBase64: useBase64, I: [1], a: BigUInt(1)) }

    private func send(_ object: [String: Any]) async {
        let data = try! JSONSerialization.data(withJSONObject: object)
        await deliver?(data)
    }

    func receive(_ data: Data) async {
        let message = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cmd = message["cmd"] as! Int
        switch cmd {
        case AppleCommand.hello:
            await send(["cmd": cmd, "capabilities": ["shouldUseBase64": useBase64, "secretSessionVersion": 1, "canFillOneTimeCodes": true]])
        case AppleCommand.handshake:
            let msg = try! JSONSerialization.jsonObject(with: Data((message["msg"] as! String).utf8)) as! [String: Any]
            let pake = try! JSONSerialization.jsonObject(with: Data(base64Encoded: msg["PAKE"] as! String)!) as! [String: Any]
            if msg["QID"] as? String == "m0" { await m0(pake) } else { await m2(pake) }
        case AppleCommand.password, AppleCommand.getCode, AppleCommand.loginNames:
            await encrypted(cmd, message)
        default:
            break
        }
    }

    private func m0(_ pake: [String: Any]) async {
        pinPopups += 1
        tid = pake["TID"] as! String
        let c = codec
        A = BigUInt(bytes: c.deserialize(pake["A"] as! String)!)
        let N = SRPGroup.N, pad = SRPGroup.byteLength
        let x = BigUInt(bytes: sha256(salt, sha256(Array((tid + ":" + pin).utf8))))
        let v = SRPGroup.g.power(x, modulus: N)
        let k = BigUInt(bytes: sha256(N.bytes, SRPGroup.g.padded(to: pad)))
        B = ((k * v) + SRPGroup.g.power(b, modulus: N)) % N
        let u = BigUInt(bytes: sha256(A.padded(to: pad), B.padded(to: pad)))
        let S = ((A * v.power(u, modulus: N)) % N).power(b, modulus: N)
        let K = sha256(S.bytes)
        key = K
        let xored = zip(sha256(N.bytes), sha256(SRPGroup.g.padded(to: pad))).map { $0 ^ $1 }
        expectedM = sha256(xored, sha256(Array(tid.utf8)), salt, A.bytes, B.bytes, K)
        hamk = sha256(A.bytes, expectedM, K)
        let answer: [String: Any] = ["TID": tid, "MSG": 1, "s": c.serialize(salt), "B": c.serialize(B.bytes), "VER": "1.0", "PROTO": 1]
        await send(["cmd": 2, "payload": ["QID": "m0", "PAKE": try! JSONSerialization.data(withJSONObject: answer).base64EncodedString()]])
    }

    private func m2(_ pake: [String: Any]) async {
        let c = codec
        let good = c.deserialize(pake["M"] as! String) == expectedM
        var answer: [String: Any] = ["TID": tid, "MSG": 3, "ErrCode": good ? 0 : 1]
        if good { answer["HAMK"] = c.serialize(hamk, prefix: false) }
        await send(["cmd": 2, "payload": ["QID": "m2", "PAKE": try! JSONSerialization.data(withJSONObject: answer).base64EncodedString()]])
    }

    private func encrypted(_ cmd: Int, _ message: [String: Any]) async {
        guard knowsSession else {
            await send(["cmd": cmd, "STATUS": 9])
            return
        }
        let payload = try! JSONSerialization.jsonObject(with: Data((message["payload"] as! String).utf8)) as! [String: Any]
        let smsg = try! JSONSerialization.jsonObject(with: Data((payload["SMSG"] as! String).utf8)) as! [String: Any]
        let session = AppleSession(tid: tid, key: Data(key.prefix(16)), useBase64: useBase64)
        let plain = try! session.open(iv16Tail: smsg["SDATA"] as! String)
        let body = try! JSONSerialization.jsonObject(with: plain) as! [String: Any]
        passwordRequests.append(body)
        var reply: [String: Any] = ["STATUS": 0]
        if cmd == AppleCommand.getCode {
            reply["Entries"] = [["username": "me@example.com", "code": "424242", "source": "totp"]]
        } else {
            reply["Entries"] = entries
        }
        let sealedPlain = try! JSONSerialization.data(withJSONObject: reply)
        let iv = Data(SRPClient.randomBytes(16))
        let sealed = try! AES.GCM.seal(sealedPlain, using: SymmetricKey(data: Data(key.prefix(16))), nonce: AES.GCM.Nonce(data: iv))
        let sdata = session.stringOf(iv + sealed.ciphertext + sealed.tag)
        await send(["cmd": cmd, "tabId": 0, "frameId": 0, "payload": ["QID": payload["QID"] as! String, "SMSG": ["TID": tid, "SDATA": sdata]]])
    }
}

private extension AppleSession {
    /// The client's outgoing order is ciphertext + tag + IV, the reverse of what `open` reads.
    func open(iv16Tail sdata: String) throws -> Data {
        let d = dataOf(sdata)!
        let iv = d.suffix(16)
        let body = d.dropLast(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: body.dropLast(16), tag: body.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }
}

private struct FakeTransport: AppleTransport {
    let helper: FakeHelper
    func send(_ json: Data) async throws { await helper.receive(json) }
}

final class AppleClientTests: XCTestCase {
    private let entries: [[String: Any]] = [
        ["USR": "other@example.com", "PWD": "wrong-password", "sites": ["example.com"]],
        ["USR": "me@example.com", "PWD": "right-password", "sites": ["example.com"]],
    ]

    private func connect(useBase64: Bool = false, store: AppleSessionStore = InMemoryAppleSessionStore()) async -> (AppleClient, FakeHelper) {
        let helper = FakeHelper(pin: "123456", useBase64: useBase64, entries: entries)
        let client = AppleClient(transport: FakeTransport(helper: helper), store: store)
        await helper.connect { [client] data in await client.deliver(data) }
        return (client, helper)
    }

    func testFullPairingAndPasswordRead() async throws {
        for base64 in [false, true] {
            let (client, helper) = await connect(useBase64: base64)
            let state = try await client.hello()
            XCTAssertEqual(state, .needsPairing)
            let shownAtHello = await helper.pinPopups
            XCTAssertEqual(shownAtHello, 0, "hello must never show a PIN")
            try await client.beginPairing()
            let afterBegin = await client.state
            XCTAssertEqual(afterBegin, .waitingForPIN)
            try await client.finishPairing(pin: "123456")
            let afterFinish = await client.state
            XCTAssertEqual(afterFinish, .paired)

            let names = try await client.loginNames(site: "example.com")
            XCTAssertEqual(names.map(\.username), ["other@example.com", "me@example.com"])
            let credential = try await client.credential(site: "example.com", username: "me@example.com")
            XCTAssertEqual(credential?.password.reveal(), "right-password")
            let code = try await client.authenticatorCode(url: "https://example.com/", username: "me@example.com")
            XCTAssertEqual(code?.reveal(), "424242")
        }
    }

    func testOnlyTheNamedLoginIsReturned() async throws {
        let (client, _) = await connect()
        try await client.hello()
        try await client.beginPairing()
        try await client.finishPairing(pin: "123456")
        let missing = try await client.credential(site: "example.com", username: "nobody@example.com")
        XCTAssertNil(missing)
    }

    func testWrongPINIsReportedAndNothingIsSaved() async throws {
        let store = InMemoryAppleSessionStore()
        let (client, _) = await connect(store: store)
        try await client.hello()
        try await client.beginPairing()
        do {
            try await client.finishPairing(pin: "000000")
            XCTFail("expected wrong PIN")
        } catch {
            XCTAssertEqual(error as? AppleProtocolError, .wrongPIN)
        }
        XCTAssertNil(store.load())
        let state = await client.state
        XCTAssertEqual(state, .needsPairing)
    }

    func testSavedSessionIsReusedWithoutAPIN() async throws {
        let store = InMemoryAppleSessionStore()
        let helper = FakeHelper(pin: "123456", useBase64: false, entries: entries)
        let first = AppleClient(transport: FakeTransport(helper: helper), store: store)
        await helper.connect { [first] data in await first.deliver(data) }
        try await first.hello()
        try await first.beginPairing()
        try await first.finishPairing(pin: "123456")
        XCTAssertNotNil(store.load())

        let second = AppleClient(transport: FakeTransport(helper: helper), store: store)
        await helper.connect { [second] data in await second.deliver(data) }
        let state = try await second.hello()
        XCTAssertEqual(state, .paired)
        let popups = await helper.pinPopups
        XCTAssertEqual(popups, 1, "the second launch shouldn't ask for a PIN")
        let credential = try await second.credential(site: "example.com", username: "me@example.com")
        XCTAssertEqual(credential?.password.reveal(), "right-password")
    }

    func testAForgottenSessionFallsBackToPairing() async throws {
        let store = InMemoryAppleSessionStore()
        let (client, helper) = await connect(store: store)
        try await client.hello()
        try await client.beginPairing()
        try await client.finishPairing(pin: "123456")
        await helper.forgetSession()
        do {
            _ = try await client.credential(site: "example.com", username: "me@example.com")
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? AppleProtocolError, .notPaired)
        }
        XCTAssertNil(store.load())
        let state = await client.state
        XCTAssertEqual(state, .needsPairing)
    }

    func testALookupOnlyReturnsAnEntryForThatSite() async throws {
        let store = InMemoryAppleSessionStore()
        let helper = FakeHelper(pin: "123456", useBase64: false, entries: [["USR": "me@example.com", "PWD": "bank-password", "sites": ["bank.com"]]])
        let client = AppleClient(transport: FakeTransport(helper: helper), store: store)
        await helper.connect { [client] data in await client.deliver(data) }
        try await client.hello()
        try await client.beginPairing()
        try await client.finishPairing(pin: "123456")
        let wrong = try await client.credential(site: "example.com", username: "me@example.com")
        XCTAssertNil(wrong, "an answer for another site must not be used")
        let right = try await client.credential(site: "bank.com", username: "me@example.com")
        XCTAssertEqual(right?.password.reveal(), "bank-password")
    }

    func testPasswordsTurnedOffIsReported() async throws {
        let (client, _) = await connect()
        try await client.hello()
        await client.deliver(try JSONSerialization.data(withJSONObject: ["cmd": AppleCommand.passwordsDisabled]))
        let state = await client.state
        if case .disabled = state { return }
        XCTFail("expected disabled, got \(state)")
    }

    func testNotPairedCannotAskForAPassword() async throws {
        let (client, helper) = await connect()
        try await client.hello()
        do {
            _ = try await client.credential(site: "example.com", username: "me@example.com")
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? AppleProtocolError, .notPaired)
        }
        let seen = await helper.passwordRequests
        XCTAssertTrue(seen.isEmpty)
    }
}
