import UserNotifications
import IRCCore

/// Decrypts the Web Push payload that APNs delivered (encrypted end-to-end by
/// soju) and turns the contained IRC line into a legible notification. Runs
/// on-device; the key material comes from the shared Keychain. If anything
/// fails, the relay's placeholder alert is shown unchanged.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        self.fallback = content

        guard let b64 = request.content.userInfo["b"] as? String,
              let body = Data(base64Encoded: b64),
              let material = WebPushKeys.load(),
              let plaintext = try? WebPushCrypto.decrypt(body: body,
                                                         privateKey: material.privateKey,
                                                         authSecret: material.authSecret),
              let line = String(data: plaintext, encoding: .utf8),
              let message = IRCMessage(parsing: line.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            contentHandler(content)   // fall back to the placeholder
            return
        }

        apply(message, to: content)
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let fallback { contentHandler(fallback) }
    }

    /// Formats a decrypted PRIVMSG/NOTICE (or an INVITE) into the notification content.
    private func apply(_ message: IRCMessage, to content: UNMutableNotificationContent) {
        if message.command == "INVITE", let channel = message.parameter(1), let source = message.source {
            guard !isIgnored(source, account: message.tags["account"]) else {
                content.title = "Arkhe"
                content.subtitle = ""
                content.body = "New message"
                content.sound = nil
                content.interruptionLevel = .passive
                return
            }
            content.title = "Invitation"
            content.subtitle = ""
            content.body = "\(source.nick) invited you to \(channel)"
            content.threadIdentifier = "invites"
            return
        }
        guard message.command == "PRIVMSG" || message.command == "NOTICE",
              let target = message.first, var text = message.trailing else { return }
        let sender = message.source?.nick ?? "?"

        // An ignored sender's message stays quiet. Without Apple's
        // notification-filtering entitlement an extension can't drop a push
        // outright, so it becomes a generic, passive alert (no sound, no lit
        // screen) that reveals neither the sender nor the text.
        if let source = message.source, isIgnored(source, account: message.tags["account"]) {
            content.title = "Arkhe"
            content.subtitle = ""
            content.body = "New message"
            content.sound = nil
            content.interruptionLevel = .passive
            content.relevanceScore = 0
            content.threadIdentifier = "ignored"
            return
        }

        // Render CTCP ACTION (/me) as "• text".
        if text.hasPrefix("\u{01}ACTION "), text.hasSuffix("\u{01}") {
            text = "• " + text.dropFirst(8).dropLast()
        } else if text.hasPrefix("\u{01}") {
            return   // ignore other CTCP; keep the placeholder
        }

        let isChannel = target.hasPrefix("#") || target.hasPrefix("&")
        // A muted conversation stays quiet: soju only skips pushes for muted
        // *nicks*, so a highlight in a muted channel still arrives.
        if TargetFlagStore.anyServer(.muted, contains: isChannel ? target : sender) {
            content.title = "Arkhe"
            content.subtitle = ""
            content.body = "New message"
            content.sound = nil
            content.interruptionLevel = .passive
            content.relevanceScore = 0
            content.threadIdentifier = "muted"
            return
        }
        content.title = isChannel ? target : sender
        content.subtitle = isChannel ? sender : ""
        content.body = text
        content.threadIdentifier = target

        // Offer the inline Reply action. The app has no runtime UUIDs for a
        // push-delivered message, so it routes the reply by conversation name:
        // the channel for a highlight, the sender for a direct message.
        content.categoryIdentifier = NotificationCategory.message
        content.userInfo[NotificationKey.target] = isChannel ? target : sender
        content.userInfo[NotificationKey.isChannel] = isChannel
    }

    /// Whether any server's ignore list matches the sender. The push doesn't
    /// carry the network's casemapping; rfc1459 folds the most, so it errs on
    /// the side of matching.
    private func isIgnored(_ source: IRCSource, account: String?) -> Bool {
        IgnoreStore.loadAll().contains {
            $0.matches(nick: source.nick, user: source.user, host: source.host,
                       account: account, caseMapping: .rfc1459)
        }
    }
}
