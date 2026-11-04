import Foundation

/// Just enough big-number arithmetic for SRP-3072. CryptoKit has no modular exponentiation.
/// Cross-checked against Node's BigInt and Apple's own client in `AppleProtocolTests`.
struct BigUInt: Equatable, Comparable {
    private(set) var limbs: [UInt32] // little-endian, no trailing zeros

    init(limbs: [UInt32] = []) {
        self.limbs = limbs
        trim()
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    init<S: Sequence>(bytes: S) where S.Element == UInt8 {
        var out: [UInt32] = []
        var current: UInt32 = 0
        var shift: UInt32 = 0
        for byte in Array(bytes).reversed() {
            current |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                out.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { out.append(current) }
        self.init(limbs: out)
    }

    init?(hex: String) {
        var s = hex
        if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
        if s.count % 2 == 1 { s = "0" + s }
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes: bytes)
    }

    private mutating func trim() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    /// Big-endian with no leading zero bytes.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        for limb in limbs.reversed() {
            out += [UInt8(limb >> 24), UInt8((limb >> 16) & 0xff), UInt8((limb >> 8) & 0xff), UInt8(limb & 0xff)]
        }
        return Array(out.drop(while: { $0 == 0 }))
    }

    func padded(to length: Int) -> [UInt8] {
        let b = bytes
        return [UInt8](repeating: 0, count: max(0, length - b.count)) + b
    }

    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let limb = i / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] & (1 << UInt32(i % 32)) != 0
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = [UInt32](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<out.count {
            let x = i < a.limbs.count ? UInt64(a.limbs[i]) : 0
            let y = i < b.limbs.count ? UInt64(b.limbs[i]) : 0
            let sum = x + y + carry
            out[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        return BigUInt(limbs: out)
    }

    /// `a - b`, where `a >= b`.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt subtraction underflow")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let y = i < b.limbs.count ? Int64(b.limbs[i]) : 0
            var d = Int64(out[i]) - y - borrow
            if d < 0 {
                d += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            out[i] = UInt32(d)
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        guard !a.isZero, !b.isZero else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        a.limbs.withUnsafeBufferPointer { x in
            b.limbs.withUnsafeBufferPointer { y in
                out.withUnsafeMutableBufferPointer { o in
                    for i in 0..<x.count {
                        var carry: UInt64 = 0
                        let xi = UInt64(x[i])
                        for j in 0..<y.count {
                            let t = xi &* UInt64(y[j]) &+ UInt64(o[i + j]) &+ carry
                            o[i + j] = UInt32(truncatingIfNeeded: t)
                            carry = t >> 32
                        }
                        o[i + y.count] = UInt32(truncatingIfNeeded: carry)
                    }
                }
            }
        }
        return BigUInt(limbs: out)
    }

    /// Knuth's algorithm D, returning the remainder only: nothing here needs the quotient.
    static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        precondition(!m.isZero, "BigUInt modulo zero")
        if a < m { return a }
        if m.limbs.count == 1 {
            var rem: UInt64 = 0
            let d = UInt64(m.limbs[0])
            for limb in a.limbs.reversed() { rem = ((rem << 32) | UInt64(limb)) % d }
            return BigUInt(rem)
        }
        let shift = UInt32(m.limbs.last!.leadingZeroBitCount)
        let v = shifted(m.limbs, by: shift, extraLimb: false)
        var u = shifted(a.limbs, by: shift, extraLimb: true)
        let n = v.count
        let mCount = u.count - n - 1
        let vTop = UInt64(v[n - 1])
        let vNext = UInt64(v[n - 2])
        let base: UInt64 = 1 << 32
        u.withUnsafeMutableBufferPointer { u in
            v.withUnsafeBufferPointer { v in
                var j = mCount
                while j >= 0 {
                    let numerator = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
                    var qhat = numerator / vTop
                    var rhat = numerator % vTop
                    while qhat >= base || qhat &* vNext > ((rhat << 32) | UInt64(u[j + n - 2])) {
                        qhat -= 1
                        rhat += vTop
                        if rhat >= base { break }
                    }
                    var borrow: Int64 = 0
                    var carry: UInt64 = 0
                    for i in 0..<n {
                        let p = qhat &* UInt64(v[i]) &+ carry
                        carry = p >> 32
                        let t = Int64(u[i + j]) - borrow - Int64(p & 0xffff_ffff)
                        u[i + j] = UInt32(truncatingIfNeeded: t)
                        borrow = t < 0 ? 1 : 0
                    }
                    let t = Int64(u[j + n]) - borrow - Int64(carry)
                    u[j + n] = UInt32(truncatingIfNeeded: t)
                    if t < 0 {
                        var c: UInt64 = 0
                        for i in 0..<n {
                            let s = UInt64(u[i + j]) + UInt64(v[i]) + c
                            u[i + j] = UInt32(truncatingIfNeeded: s)
                            c = s >> 32
                        }
                        u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + c)
                    }
                    j -= 1
                }
            }
        }
        // Undo the normalizing shift on the low n limbs.
        var r = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let low = UInt64(u[i]) >> UInt64(shift)
            let high = shift == 0 ? 0 : (UInt64(u[i + 1]) << UInt64(32 - shift)) & 0xffff_ffff
            r[i] = UInt32(truncatingIfNeeded: low | high)
        }
        return BigUInt(limbs: r)
    }

    private static func shifted(_ limbs: [UInt32], by shift: UInt32, extraLimb: Bool) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: limbs.count + (extraLimb ? 1 : 0))
        var carry: UInt32 = 0
        for i in 0..<limbs.count {
            out[i] = shift == 0 ? limbs[i] : (limbs[i] << shift) | carry
            carry = shift == 0 ? 0 : limbs[i] >> (32 - shift)
        }
        if extraLimb { out[limbs.count] = carry }
        return out
    }

    func power(_ exponent: BigUInt, modulus m: BigUInt) -> BigUInt {
        var result = BigUInt(1) % m
        let base = self % m
        let bits = exponent.bitWidth
        guard bits > 0 else { return result }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            result = (result * result) % m
            if exponent.bit(i) { result = (result * base) % m }
        }
        return result
    }
}
