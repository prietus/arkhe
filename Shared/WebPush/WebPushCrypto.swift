import Foundation
import CryptoKit

enum WebPushError: Error { case malformedPayload }

/// RFC 8291 (`aes128gcm`) Web Push decryption. The relay forwards the encrypted
/// body untouched; this runs on-device (in the Notification Service Extension)
/// to recover the plaintext IRC line. The algorithm — ECDH P-256 → HKDF-SHA256
/// → AES-128-GCM with RFC 8188 padding — is verified against the RFC 8291 §5
/// test vector.
enum WebPushCrypto {
    /// Decrypts a Web Push `aes128gcm` body using the device's private key and
    /// its 16-byte auth secret. Returns the plaintext (a single IRC line).
    static func decrypt(body: Data,
                        privateKey: P256.KeyAgreement.PrivateKey,
                        authSecret: Data) throws -> Data {
        let bytes = [UInt8](body)
        // Header: salt(16) | rs(4) | idlen(1) | keyid(idlen) | ciphertext
        guard bytes.count > 21 else { throw WebPushError.malformedPayload }
        let salt = Data(bytes[0..<16])
        let idlen = Int(bytes[20])
        let headerEnd = 21 + idlen
        guard bytes.count > headerEnd + 16 else { throw WebPushError.malformedPayload }
        let senderPublicData = Data(bytes[21..<headerEnd])       // as_public (ephemeral)
        let record = Data(bytes[headerEnd...])

        let senderPublic = try P256.KeyAgreement.PublicKey(x963Representation: senderPublicData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: senderPublic)
        let ecdh = shared.withUnsafeBytes { Data($0) }           // 32-byte X coordinate
        let receiverPublic = privateKey.publicKey.x963Representation

        // IKM = HKDF(salt=auth_secret, ikm=ecdh, info="WebPush: info"\0 ua_pub as_pub)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(receiverPublic)
        keyInfo.append(senderPublicData)
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ecdh),
                                         salt: authSecret, info: keyInfo, outputByteCount: 32)

        // CEK and NONCE then use the standard aes128gcm derivation, salted with
        // the record salt.
        var cekInfo = Data("Content-Encoding: aes128gcm".utf8); cekInfo.append(0)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                         salt: salt, info: cekInfo, outputByteCount: 16)
        var nonceInfo = Data("Content-Encoding: nonce".utf8); nonceInfo.append(0)
        let nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                              salt: salt, info: nonceInfo, outputByteCount: 12)
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })

        let cipherBytes = [UInt8](record)
        let ct = Data(cipherBytes[0..<(cipherBytes.count - 16)])
        let tag = Data(cipherBytes[(cipherBytes.count - 16)...])
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let padded = [UInt8](try AES.GCM.open(sealed, using: cek))

        // RFC 8188 padding: data | delimiter(0x02 last record) | 0x00*
        guard let end = padded.lastIndex(where: { $0 != 0 }) else {
            throw WebPushError.malformedPayload
        }
        return Data(padded[0..<end])
    }
}
