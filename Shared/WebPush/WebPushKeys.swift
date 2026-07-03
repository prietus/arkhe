import Foundation
import CryptoKit
import Security

/// The device's Web Push key material (RFC 8291): a P-256 key pair whose public
/// half and a 16-byte auth secret are handed to soju via `WEBPUSH REGISTER`, and
/// whose private half the Notification Service Extension uses to decrypt pushes.
///
/// Stored in a Keychain item shared between the app and the extension through an
/// App Group access group, with after-first-unlock accessibility so decryption
/// works while the device is locked (pushes arrive on the lock screen).
enum WebPushKeys {
    /// Shared Keychain access group. An App Group id is globally unique, so it
    /// needs no team-id prefix — keeping this fork-portable.
    static let accessGroup = "group.im.arkhe.client"
    private static let service = "im.arkhe.webpush"
    private static let account = "subscription"

    struct Material {
        let privateKey: P256.KeyAgreement.PrivateKey
        let authSecret: Data
    }

    /// Loads existing material, or generates and persists a fresh keypair.
    static func loadOrCreate() -> Material {
        if let existing = load() { return existing }
        let key = P256.KeyAgreement.PrivateKey()
        var auth = Data(count: 16)
        auth.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let material = Material(privateKey: key, authSecret: auth)
        store(material)
        return material
    }

    static func load() -> Material? {
        guard let data = read(), data.count == 48,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data.prefix(32)) else {
            return nil
        }
        return Material(privateKey: key, authSecret: data.suffix(16))
    }

    /// The `p256dh` / `auth` values (base64url) sent to soju.
    static func subscription() -> (p256dh: String, auth: String) {
        let material = loadOrCreate()
        return (material.privateKey.publicKey.x963Representation.base64URLEncodedString(),
                material.authSecret.base64URLEncodedString())
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    private static func store(_ material: Material) {
        var blob = material.privateKey.rawRepresentation   // 32 bytes
        blob.append(material.authSecret)                   // + 16 bytes = 48
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

extension Data {
    /// Unpadded base64url (RFC 4648 §5), the encoding Web Push keys use.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
