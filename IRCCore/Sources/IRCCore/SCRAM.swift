import Foundation
import CryptoKit
import CommonCrypto

/// Client side of SASL `SCRAM-SHA-256` (RFC 5802 / RFC 7677), without channel
/// binding (`n,,`). The password never crosses the wire, and the server proves
/// it knows the stored key too — a forged server signature aborts the login.
///
/// Usage: `clientFirst` → feed the server-first message to `clientFinal(…)` →
/// check the server-final message with `verify(serverFinal:)`.
public struct SCRAMClient: Sendable {
    public enum Step: Sendable, Equatable { case initial, sentFirst, sentFinal }

    public private(set) var step: Step = .initial
    private let username: String
    private let password: String
    private let clientNonce: String
    private var expectedServerSignature: Data?

    /// `nonce` is injectable for test vectors; normally random.
    public init(username: String, password: String, nonce: String? = nil) {
        self.username = username
        self.password = password
        self.clientNonce = nonce ?? Self.randomNonce()
    }

    private var clientFirstBare: String { "n=\(Self.escape(username)),r=\(clientNonce)" }

    /// `n,,n=<user>,r=<nonce>` — the first message we send.
    public mutating func clientFirst() -> Data {
        step = .sentFirst
        return Data("n,,\(clientFirstBare)".utf8)
    }

    /// Computes the client-final message (with proof) from the server-first
    /// message, or `nil` if it is malformed or the nonce doesn't extend ours.
    public mutating func clientFinal(serverFirst data: Data) -> Data? {
        guard step == .sentFirst,
              let serverFirst = String(data: data, encoding: .utf8) else { return nil }
        let attrs = Self.attributes(serverFirst)
        guard attrs["m"] == nil,
              let nonce = attrs["r"], nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count,
              let saltB64 = attrs["s"], let salt = Data(base64Encoded: saltB64),
              let iterations = attrs["i"].flatMap(UInt32.init), iterations > 0 else { return nil }

        let salted = Self.pbkdf2(password: password, salt: salt, iterations: iterations)
        let clientKey = Self.hmac(salted, "Client Key")
        let storedKey = Data(SHA256.hash(data: clientKey))
        let finalWithoutProof = "c=biws,r=\(nonce)"
        let authMessage = "\(clientFirstBare),\(serverFirst),\(finalWithoutProof)"
        let clientSignature = Self.hmac(storedKey, authMessage)
        let proof = Data(zip(clientKey, clientSignature).map { $0 ^ $1 })
        expectedServerSignature = Self.hmac(Self.hmac(salted, "Server Key"), authMessage)
        step = .sentFinal
        return Data("\(finalWithoutProof),p=\(proof.base64EncodedString())".utf8)
    }

    /// Whether the server-final message carries the signature we expect.
    public func verify(serverFinal data: Data) -> Bool {
        guard step == .sentFinal, let expected = expectedServerSignature,
              let text = String(data: data, encoding: .utf8),
              let signature = Self.attributes(text)["v"].flatMap({ Data(base64Encoded: $0) })
        else { return false }
        return signature == expected
    }

    // MARK: - Helpers

    /// `=` and `,` are reserved in SCRAM attribute values (RFC 5802 §5.1).
    static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    /// Parses `k=v,k=v` attributes (values may themselves contain `=`).
    static func attributes(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let eq = part.firstIndex(of: "="), part.distance(from: part.startIndex, to: eq) == 1
            else { continue }
            result[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return result
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        hmac(key, Data(message.utf8))
    }

    private static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func pbkdf2(password: String, salt: Data, iterations: UInt32) -> Data {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        salt.withUnsafeBytes { saltBuffer in
            _ = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.withMemoryRebound(to: Int8.self) { password in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         password.baseAddress, password.count,
                                         saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         &derived, derived.count)
                }
            }
        }
        return Data(derived)
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
