import Foundation
import SwiftUI
import UIKit
import UserNotifications
import Observation

/// Owns the app's user-notification behaviour: authorization, turning inbound
/// `NotifiableEvent`s into local notifications (with foreground suppression),
/// badge bookkeeping, tap-to-open navigation, and the APNs device-token
/// plumbing for the (not-yet-live) push server. Injected into the environment.
@MainActor
@Observable
final class NotificationManager {
    /// Whether the user has granted notification permission.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// The APNs device token, once the system hands it to us. Send this to the
    /// push server so it can target this device while Arkhe is closed. Dormant
    /// until the server bridge exists — see `docs/push-notifications.md`.
    private(set) var deviceToken: Data?

    /// Kept in sync with the app lifecycle so we can suppress alerts for the
    /// conversation the user is already looking at.
    var scenePhase: ScenePhase = .active

    private weak var store: ClientStore?
    private weak var preferences: Preferences?

    /// Running tally shown on the app-icon badge; reset when the app is active.
    private var badgeCount = 0

    private let center = UNUserNotificationCenter.current()
    /// Retained here because `UNUserNotificationCenter.delegate` is weak.
    private let delegate = NotificationDelegate()

    /// A background task kept alive while a notification reply is being sent.
    private var replyTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        // The delegate and reply-action category must be registered before the
        // app finishes launching so a Reply action can wake us in the background.
        delegate.manager = self
        center.delegate = delegate
        center.setNotificationCategories([Self.messageCategory])
    }

    /// The notification category carrying the inline "Reply" text field. Applied
    /// to every mention/DM alert, local and remote.
    private static var messageCategory: UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: NotificationAction.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message")
        return UNNotificationCategory(identifier: NotificationCategory.message,
                                      actions: [reply], intentIdentifiers: [],
                                      options: [])
    }

    /// Wires the collaborators that outlive a single view. Call once at launch.
    func attach(store: ClientStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    /// Reads the current authorization status and asks for permission on first
    /// launch when notifications are enabled. (Delegate/categories are set up in
    /// `init` so background reply-launches work even before this runs.)
    func bootstrap() {
        Task {
            await refreshAuthorization()
            if authorization == .notDetermined, preferences?.notificationsEnabled == true {
                await requestAuthorization()
            }
        }
    }

    // MARK: - Authorization

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Prompts for alert/sound/badge permission. Safe to call repeatedly; the
    /// system only shows the prompt once.
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    // MARK: - Presenting local notifications

    /// Surfaces `event` as a local notification unless preferences opt out or the
    /// user is already looking at that conversation in the foreground.
    func present(_ event: NotifiableEvent) {
        guard let preferences, preferences.notificationsEnabled else { return }
        switch event.kind {
        case .mention where !preferences.notifyOnMention: return
        case .directMessage where !preferences.notifyOnDirectMessage: return
        case .invite where !preferences.notifyOnDirectMessage: return   // personal, like a DM
        default: break
        }
        if preferences.isMuted(event.bufferName) { return }
        if isDuplicate(event) { return }
        // With remote push on, the bouncer's web push already covers alerts while
        // we're not foreground — don't also raise a local one (that's the extra
        // copy seen on the lock screen). Foreground still shows local banners for
        // other conversations; the matching remote push is dropped in willPresent.
        if scenePhase != .active, preferences.remotePushEnabled { return }
        if isOnScreen(event) { return }

        let content = UNMutableNotificationContent()
        switch event.kind {
        case .mention:
            content.title = event.conversation      // #channel
            content.subtitle = event.sender
        case .directMessage:
            content.title = event.sender
        case .invite:
            content.title = "Invitation"
        }
        content.body = preferences.notificationPreviews ? event.text
            : (event.kind == .invite ? "New invitation" : "New message")
        content.sound = preferences.notificationSound ? .default : nil
        content.threadIdentifier = event.bufferID.uuidString   // group per conversation
        // Inline Reply action — not for an invite, which has nobody to reply to.
        if event.kind != .invite { content.categoryIdentifier = NotificationCategory.message }
        content.userInfo = [
            NotificationKey.session: event.sessionID.uuidString,
            NotificationKey.buffer: event.bufferID.uuidString,
            NotificationKey.target: event.bufferName,
            NotificationKey.isChannel: event.isChannel,
        ]
        badgeCount += 1
        content.badge = NSNumber(value: badgeCount)

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// Recently-alerted `msgid`s, to collapse the same message arriving on more
    /// than one session (merged account + bound-network connections both see it).
    private var recentMsgIDs: [String: Date] = [:]

    /// True when we've already alerted for this message's `msgid` in the last few
    /// seconds. Messages without a `msgid` are never treated as duplicates.
    private func isDuplicate(_ event: NotifiableEvent) -> Bool {
        guard let msgid = event.msgid else { return false }
        let now = Date()
        recentMsgIDs = recentMsgIDs.filter { now.timeIntervalSince($0.value) < 10 }
        if recentMsgIDs[msgid] != nil { return true }
        recentMsgIDs[msgid] = now
        return false
    }

    /// True when the app is foregrounded and this exact buffer is selected.
    private func isOnScreen(_ event: NotifiableEvent) -> Bool {
        scenePhase == .active
            && store?.selectedSessionID == event.sessionID
            && store?.selectedBufferID == event.bufferID
    }

    /// Clears the icon badge; called when the app returns to the foreground.
    func clearBadge() {
        badgeCount = 0
        // setBadgeCount updates the app icon via UIApplication under the hood,
        // which asserts main-thread; guarantee it.
        onMainThread { self.center.setBadgeCount(0, withCompletionHandler: nil) }
    }

    // MARK: - Tap handling

    /// Opens the conversation identified by a tapped notification.
    func handleTap(sessionID: String?, bufferID: String?) {
        guard let sessionID, let bufferID,
              let sessionUUID = UUID(uuidString: sessionID),
              let bufferUUID = UUID(uuidString: bufferID),
              let store, let session = store.sessions[sessionUUID],
              let buffer = session.buffers.first(where: { $0.id == bufferUUID }) else { return }
        store.select(buffer, in: session)
    }

    // MARK: - Inline reply

    /// Sends a reply typed into a notification's Reply field, without opening the
    /// app. Prefers the originating session/buffer (local alerts carry their
    /// UUIDs); a remote-push alert carries only the target name, matched against
    /// any connected session. Runs under a background task and retries briefly so
    /// a reply still goes out while a session is mid-reconnect after being
    /// suspended.
    func handleReply(sessionID: String?, bufferID: String?,
                     target: String?, isChannel: Bool, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        beginReplyTask()
        Task { @MainActor in
            defer { endReplyTask() }
            for attempt in 0..<20 {
                if trySendReply(sessionID: sessionID, bufferID: bufferID,
                                target: target, isChannel: isChannel, body: body) { return }
                // Nudge back up any session the user wanted connected.
                store?.sessions.values.forEach { $0.reconnectIfDropped() }
                if attempt < 19 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    /// One attempt to route and send the reply. Returns true once it's sent.
    private func trySendReply(sessionID: String?, bufferID: String?,
                              target: String?, isChannel: Bool, body: String) -> Bool {
        guard let store else { return false }

        // Preferred path: the exact session + buffer from a local notification.
        if let sessionID, let sessionUUID = UUID(uuidString: sessionID),
           let session = store.sessions[sessionUUID] {
            session.reconnectIfDropped()
            if let bufferID, let bufferUUID = UUID(uuidString: bufferID),
               let buffer = session.buffers.first(where: { $0.id == bufferUUID }) {
                return session.sendQuickReply(body, to: buffer)
            }
            if let target, let buffer = session.replyTarget(named: target, isChannel: isChannel) {
                return session.sendQuickReply(body, to: buffer)
            }
        }

        // Fallback for remote push (no UUIDs): match the target by name on any
        // connected session.
        guard let target else { return false }
        for session in store.sessions.values where session.status == .connected {
            if let buffer = session.replyTarget(named: target, isChannel: isChannel) {
                return session.sendQuickReply(body, to: buffer)
            }
        }
        return false
    }

    // `nonisolated` + `onMainThread` so they're safe from any caller (the task
    // expiration handler arrives off-main). UIApplication asserts main-thread.
    nonisolated private func beginReplyTask() {
        endReplyTask()
        onMainThread { [weak self] in
            guard let self else { return }
            self.replyTask = UIApplication.shared.beginBackgroundTask(withName: "im.arkhe.reply") {
                [weak self] in self?.endReplyTask()
            }
        }
    }

    nonisolated private func endReplyTask() {
        onMainThread { [weak self] in
            guard let self, self.replyTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.replyTask)
            self.replyTask = .invalid
        }
    }

    // MARK: - APNs + Web Push registration

    /// The APNs device token as lowercase hex, once the system provides it.
    private(set) var deviceTokenHex: String?

    /// Asks the system for an APNs token (delivered via `AppDelegate`). Called
    /// when the user enables remote push.
    func registerForRemotePush() {
        onMainThread { UIApplication.shared.registerForRemoteNotifications() }
    }

    func didRegisterForRemotePush(token: Data) {
        deviceToken = token
        deviceTokenHex = token.map { String(format: "%02x", $0) }.joined()
        registerWebPushEverywhere()
    }

    func didFailToRegisterForRemotePush(error: Error) {
        deviceToken = nil
        deviceTokenHex = nil
    }

    /// (Re)registers a Web Push subscription on every live session whose bouncer
    /// supports `soju.im/webpush`. Idempotent — soju updates the subscription
    /// for an endpoint it already knows.
    func registerWebPushEverywhere() {
        guard let store, let preferences, preferences.remotePushEnabled,
              let token = deviceTokenHex,
              let endpoint = pushEndpoint(relayBase: preferences.pushRelayURL, token: token) else { return }
        let sub = WebPushKeys.subscription()
        for session in store.sessions.values where session.supportsWebPush {
            session.registerWebPush(endpoint: endpoint, p256dh: sub.p256dh, auth: sub.auth)
        }
    }

    /// Builds `https://<relay>/v1/<token>`, the endpoint soju POSTs to. Requires
    /// an HTTPS relay (soju refuses anything else).
    private func pushEndpoint(relayBase: String, token: String) -> String? {
        var base = relayBase.trimmingCharacters(in: .whitespaces)
        guard base.hasPrefix("https://") else { return nil }
        if base.hasSuffix("/") { base.removeLast() }
        return "\(base)/v1/\(token)"
    }
}

// Notification routing identifiers (NotificationKey / NotificationCategory /
// NotificationAction) live in `Shared/NotificationRouting.swift` so the
// Notification Service Extension shares them verbatim.

/// Thin `UNUserNotificationCenterDelegate`. Kept separate from the `@Observable`
/// manager so the manager needn't be an `NSObject`.
///
/// These use the completion-handler (NOT `async`) delegate variants on purpose.
/// iOS delivers the completion-handler variants on the **main thread** and does
/// its post-response work — the app background snapshot / state-restoration
/// update, which is main-thread-only — where the handler is invoked. The `async`
/// variants complete on the Swift cooperative pool, so iOS ran that snapshot
/// off-main and crashed (`_updateSnapshotAndStateRestoration … must be made on
/// main thread`). Staying synchronous keeps the whole exchange on main.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var manager: NotificationManager?

    /// Runs only in the foreground. A remote (web-push) alert here would just
    /// duplicate the message already shown live in the app, so drop it; local
    /// alerts (nil trigger) still show — `present(_:)` already filtered the
    /// conversation currently on screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.trigger is UNPushNotificationTrigger { completionHandler([]) }
        else { completionHandler([.banner, .list, .sound, .badge]) }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Pull out the Sendable bits so nothing non-Sendable crosses into the
        // MainActor closure below.
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo[NotificationKey.session] as? String
        let bufferID = userInfo[NotificationKey.buffer] as? String
        let target = userInfo[NotificationKey.target] as? String
        let isChannel = userInfo[NotificationKey.isChannel] as? Bool ?? false
        let replyText = response.actionIdentifier == NotificationAction.reply
            ? (response as? UNTextInputNotificationResponse)?.userText : nil
        let manager = self.manager

        // Delivered on the main thread, so drive the @MainActor manager directly.
        MainActor.assumeIsolated {
            if let replyText {
                manager?.handleReply(sessionID: sessionID, bufferID: bufferID,
                                     target: target, isChannel: isChannel, text: replyText)
            } else {
                manager?.handleTap(sessionID: sessionID, bufferID: bufferID)
            }
        }
        completionHandler()
    }
}
