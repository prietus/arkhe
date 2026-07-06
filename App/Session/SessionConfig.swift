import Foundation
import IRCCore

/// An immutable snapshot of a `ServerConfig` (plus resolved secrets) handed to
/// `IRCSession`. Keeping this a plain `Sendable` value avoids touching SwiftData
/// models or the Keychain off the main actor.
struct SessionConfig: Sendable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var useTLS: Bool
    var allowInvalidCertificates: Bool

    var nickname: String
    var username: String
    var realName: String

    var saslMode: SASLMode
    var saslAccount: String
    var saslPassword: String?
    var serverPassword: String?

    var isBouncer: Bool
    var autoJoinChannels: [String]

    var certificateData: Data?
    var certificatePassphrase: String?

    /// When set, this session is bound to one specific soju network (its id).
    /// The control/account session leaves this `nil`.
    var boundNetworkID: String?

    init(_ config: ServerConfig, clientName: String? = nil) {
        id = config.id
        name = config.name
        host = config.host
        port = UInt16(config.port)
        useTLS = config.useTLS
        allowInvalidCertificates = config.allowInvalidCertificates
        nickname = config.nickname
        // soju keys its per-client history buffers on an `@<client>` username
        // suffix (see soju's unmarshalUsername); a stable per-device name lets it
        // replay exactly what this device missed on reconnect, independent of
        // other clients. Only for a bouncer — a plain IRC network would read the
        // suffix as a literal account and reject SASL. The `/network` binding, if
        // any, is added later and coexists (soju accepts user@client/network).
        let clientSuffix = config.isBouncer ? (clientName.map { "@\($0)" } ?? "") : ""
        username = (config.username.isEmpty ? config.nickname : config.username) + clientSuffix
        realName = config.realName.isEmpty ? config.nickname : config.realName
        saslMode = config.saslMode
        saslAccount = (config.saslAccount.isEmpty ? config.nickname : config.saslAccount) + clientSuffix
        saslPassword = config.saslPassword
        serverPassword = config.serverPassword
        isBouncer = config.isBouncer
        autoJoinChannels = config.autoJoinChannels
        certificateData = config.certificateData
        certificatePassphrase = config.certificatePassphrase
        boundNetworkID = nil
    }

    /// Derives a session bound to a single soju network, reusing the base
    /// account's connection details and credentials. The network is bound the
    /// proven soju way — the username and SASL account carry a `/network`
    /// suffix (e.g. `teraflops/libera`).
    init(boundNetwork network: BouncerNetwork, base: SessionConfig) {
        // Replace any existing `/suffix` with this network's name.
        func bind(_ value: String) -> String {
            let bare = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            return "\(bare)/\(network.name)"
        }
        id = UUID()
        name = network.name
        host = base.host
        port = base.port
        useTLS = base.useTLS
        allowInvalidCertificates = base.allowInvalidCertificates
        nickname = network.nickname ?? base.nickname
        username = bind(base.username)
        realName = base.realName
        saslMode = base.saslMode
        saslAccount = bind(base.saslAccount)
        saslPassword = base.saslPassword
        serverPassword = base.serverPassword
        isBouncer = true
        autoJoinChannels = []   // soju replays the network's joins
        certificateData = base.certificateData
        certificatePassphrase = base.certificatePassphrase
        boundNetworkID = network.id
    }

    /// True when this session targets a single soju network rather than the
    /// merged account view: either a derived bound-network session, or a base
    /// config whose username carries an explicit `/network` suffix.
    var isExplicitlyBound: Bool {
        boundNetworkID != nil || username.contains("/")
    }

    /// Capabilities to request. soju honours a `user/network` username binding
    /// only while the client does NOT negotiate `soju.im/bouncer-networks` —
    /// enabling it switches the connection to merged multi-network mode and
    /// ignores the suffix. So a session bound to one network drops those caps
    /// and gets exactly that network's channels.
    var desiredCaps: Set<String> {
        guard isExplicitlyBound else { return CapabilityName.desired }
        return CapabilityName.desired.subtracting([
            CapabilityName.bouncerNetworks,
            CapabilityName.bouncerNetworksNotify,
        ])
    }

    /// The SASL mechanism to negotiate, resolved from the configured mode.
    var saslMechanism: SASLMechanism? {
        switch saslMode {
        case .none:
            return nil
        case .plain:
            guard let password = saslPassword else { return nil }
            return .plain(authcid: saslAccount, password: password)
        case .external:
            return .external()
        }
    }
}
