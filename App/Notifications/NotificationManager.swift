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

    /// Wires the collaborators that outlive a single view. Call once at launch.
    func attach(store: ClientStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    /// Becomes the notification-center delegate, reads the current status, and
    /// asks for permission on first launch when notifications are enabled.
    func bootstrap() {
        delegate.manager = self
        center.delegate = delegate
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
        default: break
        }
        if isOnScreen(event) { return }

        let content = UNMutableNotificationContent()
        switch event.kind {
        case .mention:
            content.title = event.conversation      // #channel
            content.subtitle = event.sender
        case .directMessage:
            content.title = event.sender
        }
        content.body = preferences.notificationPreviews ? event.text : "New message"
        content.sound = preferences.notificationSound ? .default : nil
        content.threadIdentifier = event.bufferID.uuidString   // group per conversation
        content.userInfo = [
            NotificationKey.session: event.sessionID.uuidString,
            NotificationKey.buffer: event.bufferID.uuidString,
        ]
        badgeCount += 1
        content.badge = NSNumber(value: badgeCount)

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
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
        center.setBadgeCount(0, withCompletionHandler: nil)
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

    // MARK: - APNs + Web Push registration

    /// The APNs device token as lowercase hex, once the system provides it.
    private(set) var deviceTokenHex: String?

    /// Asks the system for an APNs token (delivered via `AppDelegate`). Called
    /// when the user enables remote push.
    func registerForRemotePush() {
        UIApplication.shared.registerForRemoteNotifications()
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

/// Keys shared between the notification payload and the tap handler.
enum NotificationKey {
    static let session = "sessionID"
    static let buffer = "bufferID"
}

/// Thin `UNUserNotificationCenterDelegate`. Kept separate from the `@Observable`
/// manager so the manager needn't be an `NSObject`.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var manager: NotificationManager?

    /// Show a banner even in the foreground — `present(_:)` already dropped
    /// alerts for the conversation currently on screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Extract the Sendable bits before hopping to the main actor.
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo[NotificationKey.session] as? String
        let bufferID = userInfo[NotificationKey.buffer] as? String
        await MainActor.run { [weak manager] in
            manager?.handleTap(sessionID: sessionID, bufferID: bufferID)
        }
    }
}
