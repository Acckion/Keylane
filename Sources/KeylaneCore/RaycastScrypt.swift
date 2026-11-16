import Foundation
import CommonCrypto

/// RFC 7914 scrypt. Fixed resource bounds for Raycast RAYCFG3, never file-supplied cost parameters.
enum RaycastScrypt {
    static func derive(password: Data, salt: Data, n: Int = 16384, r: Int = 8, p: Int = 1, length: Int = 32) throws -> Data {
        guard n > 1, n & (n - 1) == 0, n <= 16384, r > 0, r <= 8, p > 0, p <= 1, length > 0, length <= 64 else { throw ConfigurationError("不支持的密钥派生参数。") }
        var initial = try pbkdf(password, salt, count: p * 128 * r)
        let words = 32 * r
        for block in 0..<p {
            var x = [UInt32](repeating: 0, count: words)
            for i in 0..<words {
                let offset = block * words * 4 + i * 4
                x[i] = UInt32(initial[offset]) | UInt32(initial[offset + 1]) << 8 | UInt32(initial[offset + 2]) << 16 | UInt32(initial[offset + 3]) << 24
            }
            var memory = [UInt32](repeating: 0, count: n * words)
            var scratch = [UInt32](repeating: 0, count: words)
            var state = [UInt32](repeating: 0, count: 16)
            for i in 0..<n {
                memory.replaceSubrange(i * words..<(i + 1) * words, with: x)
                mix(&x, scratch: &scratch, state: &state, r: r)
            }
            for _ in 0..<n {
                let j = Int(x[(2 * r - 1) * 16] & UInt32(n - 1))
                for k in 0..<words { x[k] ^= memory[j * words + k] }
                mix(&x, scratch: &scratch, state: &state, r: r)
            }
            for i in 0..<words {
                for byte in 0..<4 { initial[block * words * 4 + i * 4 + byte] = UInt8(truncatingIfNeeded: x[i] >> (byte * 8)) }
            }
            // Best-effort overwrite of the large work buffers before releasing them.
            for i in memory.indices { memory[i] = 0 }
        }
        return try pbkdf(password, initial, count: length)
    }
    private static func pbkdf(_ password: Data, _ salt: Data, count: Int) throws -> Data {
        var output = Data(count: count)
        let status = output.withUnsafeMutableBytes { out in password.withUnsafeBytes { pass in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.bindMemory(to: Int8.self).baseAddress, password.count,
                                salt.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1,
                                out.bindMemory(to: UInt8.self).baseAddress, count)
        } } }
        guard status == kCCSuccess else { throw ConfigurationError("密钥派生失败。") }
        return output
    }
    @inline(__always) private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
    private static func salsa(_ b: inout [UInt32]) {
        var x = b
        for _ in 0..<4 {
            x[4] ^= rotate(x[0] &+ x[12], 7); x[8] ^= rotate(x[4] &+ x[0], 9); x[12] ^= rotate(x[8] &+ x[4], 13); x[0] ^= rotate(x[12] &+ x[8], 18)
            x[9] ^= rotate(x[5] &+ x[1], 7); x[13] ^= rotate(x[9] &+ x[5], 9); x[1] ^= rotate(x[13] &+ x[9], 13); x[5] ^= rotate(x[1] &+ x[13], 18)
            x[14] ^= rotate(x[10] &+ x[6], 7); x[2] ^= rotate(x[14] &+ x[10], 9); x[6] ^= rotate(x[2] &+ x[14], 13); x[10] ^= rotate(x[6] &+ x[2], 18)
            x[3] ^= rotate(x[15] &+ x[11], 7); x[7] ^= rotate(x[3] &+ x[15], 9); x[11] ^= rotate(x[7] &+ x[3], 13); x[15] ^= rotate(x[11] &+ x[7], 18)
            x[1] ^= rotate(x[0] &+ x[3], 7); x[2] ^= rotate(x[1] &+ x[0], 9); x[3] ^= rotate(x[2] &+ x[1], 13); x[0] ^= rotate(x[3] &+ x[2], 18)
            x[6] ^= rotate(x[5] &+ x[4], 7); x[7] ^= rotate(x[6] &+ x[5], 9); x[4] ^= rotate(x[7] &+ x[6], 13); x[5] ^= rotate(x[4] &+ x[7], 18)
            x[11] ^= rotate(x[10] &+ x[9], 7); x[8] ^= rotate(x[11] &+ x[10], 9); x[9] ^= rotate(x[8] &+ x[11], 13); x[10] ^= rotate(x[9] &+ x[8], 18)
            x[12] ^= rotate(x[15] &+ x[14], 7); x[13] ^= rotate(x[12] &+ x[15], 9); x[14] ^= rotate(x[13] &+ x[12], 13); x[15] ^= rotate(x[14] &+ x[13], 18)
        }
        for i in 0..<16 { b[i] &+= x[i] }
    }
    private static func mix(_ x: inout [UInt32], scratch: inout [UInt32], state: inout [UInt32], r: Int) {
        for k in 0..<16 { state[k] = x[(2 * r - 1) * 16 + k] }
        for i in 0..<(2 * r) {
            for k in 0..<16 { state[k] ^= x[i * 16 + k] }
            salsa(&state)
            let destination = (i / 2 + (i % 2) * r) * 16
            for k in 0..<16 { scratch[destination + k] = state[k] }
        }
        swap(&x, &scratch)
    }
}
