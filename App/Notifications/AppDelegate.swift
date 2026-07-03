import SwiftUI
import UIKit

/// Minimal application delegate, adapted into the SwiftUI lifecycle solely to
/// receive APNs device-token callbacks (which have no SwiftUI equivalent).
/// Everything else lives in `ArkheApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Wired by `ArkheApp` so token callbacks reach the notification manager.
    weak var notifications: NotificationManager?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        notifications?.didRegisterForRemotePush(token: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        notifications?.didFailToRegisterForRemotePush(error: error)
    }
}
