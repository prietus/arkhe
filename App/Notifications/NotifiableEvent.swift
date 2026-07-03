import Foundation

/// A locally-detected event worth alerting the user about: a highlight (someone
/// said your nick in a channel) or a direct message. `IRCSession` builds these
/// on the main actor; `NotificationManager` decides whether to surface them.
struct NotifiableEvent: Sendable {
    enum Kind: Sendable { case mention, directMessage }

    let kind: Kind
    /// The session (network) the message arrived on.
    let sessionID: UUID
    /// The buffer to open when the notification is tapped.
    let bufferID: UUID
    /// What the notification titles itself with: the channel for a mention, the
    /// sender for a direct message.
    let conversation: String
    let sender: String
    let text: String
}
