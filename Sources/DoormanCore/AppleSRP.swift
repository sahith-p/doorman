import Foundation
import CryptoKit

/// The pairing and message encryption Apple's password helper expects from its browser extension:
/// SRP over the RFC 5054 3072-bit group, then AES-128-GCM with a 16-byte IV. Read from Apple's own
/// extension, and checked against it by fixture in `AppleProtocolTests`. It runs here in Doorman so
/// the hidden browser only ever forwards ciphertext.
enum SRPGroup {
    static let N = BigUInt(hex: """
    FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
    EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
    EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
    83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
    E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510\
    15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
    ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
    BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
    """)!
    static let g = BigUInt(5)
    static let byteLength = 384
}

func sha256(_ parts: [UInt8]...) -> [UInt8] {
    var hasher = SHA256()
    for part in parts { hasher.update(data: part) }
    return Array(hasher.finalize())
}

public enum AppleProtocolError: Error, Equatable, Sendable {
    case badMessage(String)
    case wrongPIN
    case serverProofFailed
    case decryptFailed
    case timedOut
    case notPaired
    case disconnected
}

/// One client side of the exchange. `I` and `a` can be injected so the math can be compared to fixtures.
struct SRPClient {
    let useBase64: Bool
    let I: [UInt8]
    let a: BigUInt
    let A: BigUInt

    init(useBase64: Bool, I: [UInt8]? = nil, a: BigUInt? = nil) {
        self.useBase64 = useBase64
        // A leading zero byte would change how the identifier is written, so don't start with one.
        var id = I ?? SRPClient.randomBytes(16)
        if I == nil, id[0] == 0 { id[0] = 1 }
        self.I = id
        self.a = a ?? BigUInt(bytes: SRPClient.randomBytes(32))
        self.A = SRPGroup.g.power(self.a, modulus: SRPGroup.N)
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &out)
        precondition(status == errSecSuccess, "system random failed")
        return out
    }

    func serialize(_ bytes: [UInt8], prefix: Bool = true) -> String {
        if useBase64 { return Data(bytes).base64EncodedString() }
        return (prefix ? "0x" : "") + bytes.map { String(format: "%02x", $0) }.joined()
    }

    func deserialize(_ s: String) -> [UInt8]? {
        if useBase64 { return Data(base64Encoded: s).map(Array.init) }
        var h = s
        if h.hasPrefix("0x") { h = String(h.dropFirst(2)) }
        if h.count % 2 == 1 { h = "0" + h }
        var out: [UInt8] = []
        out.reserveCapacity(h.count / 2)
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    var tid: String { serialize(I) }

    struct Proof {
        let M: [UInt8]
        let HAMK: [UInt8]
        let sessionKey: [UInt8]
    }

    func proof(pin: String, salt: [UInt8], B: BigUInt) throws -> Proof {
        let N = SRPGroup.N
        guard !(B % N).isZero else { throw AppleProtocolError.badMessage("server public key is zero") }
        let pad = SRPGroup.byteLength
        let u = BigUInt(bytes: sha256(A.padded(to: pad), B.padded(to: pad)))
        let k = BigUInt(bytes: sha256(N.bytes, SRPGroup.g.padded(to: pad)))
        let x = BigUInt(bytes: sha256(salt, sha256(Array((tid + ":" + pin).utf8))))
        let v = SRPGroup.g.power(x, modulus: N)
        let kv = (k * v) % N
        let base = (B % N + N - kv) % N
        let S = base.power(a + u * x, modulus: N)
        let K = sha256(S.bytes)
        let hN = sha256(N.bytes)
        let hG = sha256(SRPGroup.g.padded(to: pad))
        let xored = zip(hN, hG).map { $0 ^ $1 }
        let M = sha256(xored, sha256(Array(tid.utf8)), salt, A.bytes, B.bytes, K)
        let HAMK = sha256(A.bytes, M, K)
        return Proof(M: M, HAMK: HAMK, sessionKey: K)
    }
}

/// The session a finished pairing leaves behind: the session identifier and the first 128 bits of K.
public struct AppleSession: Codable, Equatable, Sendable {
    public var tid: String
    public var key: Data
    public var useBase64: Bool

    public init(tid: String, key: Data, useBase64: Bool) {
        self.tid = tid
        self.key = key
        self.useBase64 = useBase64
    }

    private var symmetricKey: SymmetricKey { SymmetricKey(data: key) }

    func stringOf(_ data: Data) -> String {
        useBase64 ? data.base64EncodedString() : data.map { String(format: "%02x", $0) }.joined()
    }

    func dataOf(_ s: String) -> Data? {
        if useBase64 { return Data(base64Encoded: s) }
        var h = s
        if h.hasPrefix("0x") { h = String(h.dropFirst(2)) }
        guard h.count % 2 == 0 else { return nil }
        var out = Data(capacity: h.count / 2)
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// `{TID, SDATA}` as a JSON string. Outgoing: ciphertext + tag + IV.
    func smsg(_ object: [String: Any], iv: Data? = nil) throws -> String {
        let plain = try JSONSerialization.data(withJSONObject: object)
        let nonceBytes = iv ?? Data(SRPClient.randomBytes(16))
        let sealed = try AES.GCM.seal(plain, using: symmetricKey, nonce: AES.GCM.Nonce(data: nonceBytes))
        let sdata = sealed.ciphertext + sealed.tag + nonceBytes
        let out = try JSONSerialization.data(withJSONObject: ["TID": tid, "SDATA": stringOf(sdata)])
        return String(decoding: out, as: UTF8.self)
    }

    /// Incoming SDATA: IV + ciphertext + tag.
    func open(sdata: String) throws -> Data {
        guard let d = dataOf(sdata), d.count >= 32 else { throw AppleProtocolError.decryptFailed }
        let iv = d.prefix(16)
        let body = d.dropFirst(16)
        let ciphertext = body.dropLast(16)
        let tag = body.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw AppleProtocolError.decryptFailed
        }
    }
}
