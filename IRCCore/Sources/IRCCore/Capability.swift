import Foundation

/// A single IRCv3 capability as advertised in `CAP LS`, optionally carrying a
/// value (e.g. `sasl=PLAIN,EXTERNAL` or `draft/chathistory`).
public struct Capability: Sendable, Equatable, Hashable {
    public let name: String
    public let value: String?

    public init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }

    /// Parses one token from a `CAP LS` list, e.g. `sasl=PLAIN,EXTERNAL`.
    public init(token: Substring) {
        if let eq = token.firstIndex(of: "=") {
            name = String(token[..<eq])
            value = String(token[token.index(after: eq)...])
        } else {
            name = String(token)
            value = nil
        }
    }

    /// For value-bearing caps that list comma-separated items (like `sasl`),
    /// the parsed list. Empty when there is no value.
    public var values: [String] {
        value?.split(separator: ",").map(String.init) ?? []
    }
}

/// Well-known capability names the client understands. Centralised so the
/// negotiator and session driver agree on spelling.
public enum CapabilityName {
    public static let sasl = "sasl"
    public static let messageTags = "message-tags"
    public static let serverTime = "server-time"
    public static let batch = "batch"
    public static let labeledResponse = "labeled-response"
    public static let echoMessage = "echo-message"
    public static let accountNotify = "account-notify"
    public static let accountTag = "account-tag"
    public static let awayNotify = "away-notify"
    public static let chghost = "chghost"
    public static let extendedJoin = "extended-join"
    public static let multiPrefix = "multi-prefix"
    public static let userhostInNames = "userhost-in-names"
    public static let capNotify = "cap-notify"
    public static let setname = "setname"
    public static let inviteNotify = "invite-notify"
    public static let standardReplies = "standard-replies"
    /// Ratified successor of `soju.im/no-implicit-names` (Ergo 2.19+, Libera).
    public static let noImplicitNames = "no-implicit-names"

    // Drafts widely deployed (and supported by soju)
    public static let multiline = "draft/multiline"
    public static let chathistory = "draft/chathistory"
    public static let eventPlayback = "draft/event-playback"
    public static let messageRedaction = "draft/message-redaction"
    public static let metadata = "draft/metadata-2"
    public static let readMarker = "draft/read-marker"
    public static let typing = "message-tags" // typing uses +typing tag

    // soju vendor extensions for bouncer multi-network support
    public static let bouncerNetworks = "soju.im/bouncer-networks"
    public static let bouncerNetworksNotify = "soju.im/bouncer-networks-notify"
    public static let sojuNoImplicitNames = "soju.im/no-implicit-names"
    /// soju's per-target metadata keys (over `draft/metadata-2`): its block list
    /// drops a blocked nick's messages and pushes on the bouncer itself.
    public static let sojuBlocked = "soju.im/blocked"
    /// Web Push: lets the bouncer push highlights/DMs while the app is closed.
    public static let webpush = "soju.im/webpush"

    /// The capabilities the client requests when offered. SASL is requested
    /// only when credentials are configured (handled by the negotiator).
    public static let desired: Set<String> = [
        sasl, messageTags, serverTime, batch, labeledResponse, echoMessage,
        accountNotify, accountTag, awayNotify, chghost, extendedJoin,
        multiPrefix, userhostInNames, capNotify, setname, inviteNotify,
        standardReplies, chathistory, eventPlayback, messageRedaction, readMarker,
        multiline, bouncerNetworks, bouncerNetworksNotify, noImplicitNames, sojuNoImplicitNames, webpush,
        metadata,
    ]
}
