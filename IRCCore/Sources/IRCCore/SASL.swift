import Foundation

/// SASL authentication mechanisms supported by the client.
///
/// `PLAIN` sends username/password over the (already TLS-encrypted) link;
/// `EXTERNAL` defers to the TLS client certificate (CertFP) and carries no
/// secret of its own.
public enum SASLMechanism: Sendable, Equatable {
    case plain(authcid: String, password: String, authzid: String = "")
    case external(authzid: String = "")

    /// The mechanism name advertised in `AUTHENTICATE <name>`.
    public var name: String {
        switch self {
        case .plain: return "PLAIN"
        case .external: return "EXTERNAL"
        }
    }
}

/// Maximum size of a single `AUTHENTICATE` payload chunk, per the SASL spec.
private let saslChunkSize = 400

public enum SASL {
    /// Builds the base64-encoded initial response for a mechanism. `nil` means
    /// "no initial response yet" — for `EXTERNAL`, the client waits for the
    /// server's `AUTHENTICATE +` before sending the (usually empty) authzid.
    public static func initialResponse(for mechanism: SASLMechanism) -> Data? {
        switch mechanism {
        case let .plain(authcid, password, authzid):
            var bytes = Data()
            bytes.append(contentsOf: authzid.utf8)
            bytes.append(0)
            bytes.append(contentsOf: authcid.utf8)
            bytes.append(0)
            bytes.append(contentsOf: password.utf8)
            return bytes
        case let .external(authzid):
            return Data(authzid.utf8)
        }
    }

    /// Splits a raw SASL response into the sequence of `AUTHENTICATE` payloads
    /// to send on the wire.
    ///
    /// Per spec, the base64 response is split into chunks of up to 400 bytes.
    /// An empty response is sent as a single `+`, and when the response length
    /// is an exact multiple of 400 a trailing `+` terminator is appended so the
    /// server knows the previous full chunk was the last.
    public static func chunkedPayloads(for response: Data) -> [String] {
        let encoded = response.base64EncodedString()
        guard !encoded.isEmpty else { return ["+"] }

        var payloads: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: saslChunkSize, limitedBy: encoded.endIndex) ?? encoded.endIndex
            payloads.append(String(encoded[index..<end]))
            index = end
        }
        if encoded.count % saslChunkSize == 0 {
            payloads.append("+")
        }
        return payloads
    }

    /// Decodes a server `AUTHENTICATE` challenge payload (`+` means empty).
    public static func decodeChallenge(_ payload: String) -> Data? {
        if payload == "+" { return Data() }
        return Data(base64Encoded: payload)
    }
}
