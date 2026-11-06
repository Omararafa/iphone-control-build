// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

enum GlassesTrust {
    struct Pair: Codable { let id: String; let key: Data }
    struct Result { let code: String; let pair: Pair }
    static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String, count: Int) -> Data? {
        guard text.count <= 100, text.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count == count, b64(data) == text else { return nil }
        return data
    }
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func mac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func matches(_ key: Data, _ data: Data, _ received: String) -> Bool {
        guard let bytes = decode(received, count: 32) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: data, using: SymmetricKey(data: key))
    }
    static func derive(_ secret: Data, glasses: Data, phone: Data) -> Result {
        let prk = mac(Data("glasses-remote/pair/v1".utf8), secret + glasses + phone)
        let number = mac(prk, Data("code".utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Result(code: String(format: "%06u", number % 1_000_000),
                      pair: Pair(id: b64(mac(prk, Data("id".utf8)).prefix(12)), key: mac(prk, Data("key".utf8))))
    }
    static func session(_ key: Data, glasses: Data, phone: Data) -> Data {
        mac(key, Data("session".utf8) + glasses + phone)
    }
    static func sdp(_ kind: String, _ text: String) -> Data { Data((kind + "\n" + text).utf8) }
}
