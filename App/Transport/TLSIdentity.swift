import Foundation
import Security
import CryptoKit

/// A TLS client identity used for CertFP (SASL EXTERNAL). Wraps a `SecIdentity`
/// (private key + certificate) imported from a PKCS#12 (`.p12`) blob.
struct TLSIdentity: @unchecked Sendable {
    let secIdentity: SecIdentity
    /// The leaf certificate, used to compute the CertFP fingerprint.
    let certificate: SecCertificate

    enum ImportError: LocalizedError {
        case badPassphraseOrData(OSStatus)
        case noIdentityInBlob
        case noCertificate

        var errorDescription: String? {
            switch self {
            case let .badPassphraseOrData(status):
                return "Couldn't import the certificate (status \(status)). Check the passphrase."
            case .noIdentityInBlob:
                return "The file doesn't contain an identity (private key + certificate)."
            case .noCertificate:
                return "The identity has no associated certificate."
            }
        }
    }

    /// Imports an identity from raw PKCS#12 data.
    init(pkcs12 data: Data, passphrase: String) throws {
        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw ImportError.badPassphraseOrData(status) }

        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw ImportError.noIdentityInBlob
        }
        // SecIdentity is a CF type; bridge through the opaque value.
        let secIdentity = unsafeDowncast(identity as AnyObject, to: SecIdentity.self)
        self.secIdentity = secIdentity

        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &cert) == errSecSuccess, let cert else {
            throw ImportError.noCertificate
        }
        self.certificate = cert
    }

    /// The SHA-256 CertFP fingerprint as lowercase hex — what networks/soju
    /// store to recognise the client (`/msg NickServ CERT ADD`).
    var sha256Fingerprint: String {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
