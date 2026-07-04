import Foundation

/// Identifiers shared verbatim between the app and the Notification Service
/// Extension so a notification built by either side routes and offers the inline
/// Reply action consistently. Compiled into both targets via `Shared/`.

/// `userInfo` keys carried on a mention/DM notification.
enum NotificationKey {
    static let session = "sessionID"
    static let buffer = "bufferID"
    /// The conversation name (channel or query nick) — used to route a reply
    /// from a remote-push alert, which has no runtime UUIDs.
    static let target = "target"
    static let isChannel = "isChannel"
}

/// The notification category that carries the inline Reply action.
enum NotificationCategory { static let message = "message" }

/// Action identifier for the inline Reply text field.
enum NotificationAction { static let reply = "reply" }
