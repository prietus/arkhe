import Foundation

/// A locally-detected event worth alerting the user about: a highlight (someone
/// said your nick in a channel), a direct message, or an invitation to a channel. `IRCSession` builds these
/// on the main actor; `NotificationManager` decides whether to surface them.
struct NotifiableEvent: Sendable {
    enum Kind: Sendable { case mention, directMessage, invite }

    let kind: Kind
    /// The session (network) the message arrived on.
    let sessionID: UUID
    /// The buffer to open when the notification is tapped.
    let bufferID: UUID
    /// What the notification titles itself with: the channel for a mention, the
    /// sender for a direct message.
    let conversation: String
    /// The buffer's name (channel or query nick) — the stable key for muting and
    /// for routing a reply typed into the notification.
    let bufferName: String
    /// IRCv3 `msgid`, when present — collapses the same message arriving on more
    /// than one session (e.g. a merged account session plus a bound-network one).
    let msgid: String?
    let sender: String
    let text: String

    /// A mention is always in a channel; a direct message is a query. An
    /// invite opens the status window, where the /join hint is.
    var isChannel: Bool { kind == .mention }
}
