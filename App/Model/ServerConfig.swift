import Foundation
import SwiftData

/// The SASL mechanism a server should authenticate with.
enum SASLMode: String, Codable, CaseIterable, Identifiable {
    case none
    case plain
    case external   // CertFP

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .plain: return "PLAIN (username/password)"
        case .external: return "EXTERNAL (CertFP)"
        }
    }
}

/// A persisted server / bouncer definition. Secrets (passwords, certificate
/// passphrase) are NOT stored here — they live in the Keychain, keyed by `id`.
@Model
final class ServerConfig {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var useTLS: Bool
    var allowInvalidCertificates: Bool

    var nickname: String
    var username: String
    var realName: String

    var saslModeRaw: String
    /// SASL account name. For soju, often `user/network` to bind a bouncer
    /// network at connect time.
    var saslAccount: String

    /// `true` when this connection targets a soju-style bouncer.
    var isBouncer: Bool
    var autoConnect: Bool
    var autoJoinChannels: [String]

    /// PKCS#12 (`.p12`) client identity for CertFP. The passphrase is in the
    /// Keychain under `"<id>.certPassphrase"`.
    @Attribute(.externalStorage) var certificateData: Data?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 6697,
        useTLS: Bool = true,
        allowInvalidCertificates: Bool = false,
        nickname: String = "",
        username: String = "",
        realName: String = "",
        saslMode: SASLMode = .none,
        saslAccount: String = "",
        isBouncer: Bool = false,
        autoConnect: Bool = false,
        autoJoinChannels: [String] = [],
        certificateData: Data? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowInvalidCertificates = allowInvalidCertificates
        self.nickname = nickname
        self.username = username.isEmpty ? nickname : username
        self.realName = realName.isEmpty ? nickname : realName
        self.saslModeRaw = saslMode.rawValue
        self.saslAccount = saslAccount
        self.isBouncer = isBouncer
        self.autoConnect = autoConnect
        self.autoJoinChannels = autoJoinChannels
        self.certificateData = certificateData
        self.sortOrder = sortOrder
    }

    var saslMode: SASLMode {
        get { SASLMode(rawValue: saslModeRaw) ?? .none }
        set { saslModeRaw = newValue.rawValue }
    }

    // MARK: - Keychain-backed secrets

    var serverPassword: String? {
        get { Keychain.get("\(id).serverPassword") }
        set { Keychain.set(newValue, for: "\(id).serverPassword") }
    }

    var saslPassword: String? {
        get { Keychain.get("\(id).saslPassword") }
        set { Keychain.set(newValue, for: "\(id).saslPassword") }
    }

    var certificatePassphrase: String? {
        get { Keychain.get("\(id).certPassphrase") }
        set { Keychain.set(newValue, for: "\(id).certPassphrase") }
    }
}
