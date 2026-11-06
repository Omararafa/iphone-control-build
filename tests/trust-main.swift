// Protocol interoperability vector shared with Glasscast's browser and Android tests.
import Foundation
import CryptoKit

func bytes(_ s: String, _ n: Int = 32) -> Data { GlassesTrust.decode(s, count: n)! }
let g = bytes("BAIX5hfwtkQ5KCePlpmeaaI6TywVK99tbN9m5bgCgtTtGUp968uXcS0t2jyoWqh2Wlb0X8dYWZZS8ol8ZTBuV5Q", 65)
let p = bytes("BNZak5d8qj0bCBhS_1ennkZfFmBXcwS66tUF3TpIWJzzUBheiVNy32Ih6joTdVfkc_3bZ1XwW9UHw8Uz_OnJEoU", 65)
let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes("IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"))
let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: g)
let z = try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
precondition(GlassesTrust.b64(z) == "zPwmH1gZPJjKStSlO7rG8O4pvE1IQ4CQRGkIYiynmvY")
precondition(GlassesTrust.b64(GlassesTrust.hash(g)) == "K60P1hDZnq5EPpMqJhQryh5fqZW0UYRSgn547x8xf_A")
let pair = GlassesTrust.derive(z, glasses: g, phone: p)
precondition(pair.code == "752138")
precondition(pair.pair.id == "e7OWfrvMTctc7H2n")
precondition(GlassesTrust.b64(pair.pair.key) == "2rZ3D8DKYzvJGm7ap1t99fPIpg7gyA1oaCtLy81N734")
let sk = GlassesTrust.session(pair.pair.key, glasses: bytes("MzMzMzMzMzMzMzMzMzMzMw", 16), phone: bytes("RERERERERERERERERERERA", 16))
precondition(GlassesTrust.matches(sk, Data("phone".utf8), "8kaJJpg5ZFDDEx2mYJXnoXEs6kX0KSCzmN2-G9JReeE"))
precondition(GlassesTrust.matches(sk, Data("glasses".utf8), "iRMu34EQiaj6y2JJ7TeSteLdEFjFNmK3quM8-6HTYVk"))
let sdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"
precondition(GlassesTrust.matches(sk, GlassesTrust.sdp("offer", sdp), "m1tV9PeYr9t7ILJdrnakF4xUwa5KzeWJkI43l5o_5hY"))
precondition(GlassesTrust.matches(sk, GlassesTrust.sdp("answer", sdp), "2pwIizM2lmNqQdeOT61Hmp3zdDgucN3DnbSEz3DU-U8"))
precondition(!GlassesTrust.matches(sk, GlassesTrust.sdp("answer", sdp + "a=x\r\n"), "2pwIizM2lmNqQdeOT61Hmp3zdDgucN3DnbSEz3DU-U8"))
precondition(!GlassesTrust.matches(sk, Data("phone".utf8), "bad"))
precondition(GlassesTrust.decode("not base64url!", count: 32) == nil)
precondition(GlassesTrust.decode("====", count: 32) == nil)
precondition(GlassesTrust.decode(String(repeating: "A", count: 1000), count: 32) == nil)
var invalidPoint = g; invalidPoint[64] ^= 1
precondition((try? P256.KeyAgreement.PublicKey(x963Representation: invalidPoint)) == nil)
print("PASS: iOS pairing, ECDH, session proofs, SDP integrity and invalid-input vectors match Glasscast")
