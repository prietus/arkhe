import SwiftUI
import SwiftData

@main
struct ArkheApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ClientStore
    @State private var preferences: Preferences
    @State private var uploader: UploaderSettings
    @State private var notifications: NotificationManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let notifications = NotificationManager()
        let preferences = Preferences()
        let store = ClientStore(notifications: notifications)
        notifications.attach(store: store, preferences: preferences)
        _store = State(initialValue: store)
        _preferences = State(initialValue: preferences)
        _uploader = State(initialValue: UploaderSettings())
        _notifications = State(initialValue: notifications)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(preferences)
                .environment(uploader)
                .environment(notifications)
                .task {
                    appDelegate.notifications = notifications
                    notifications.scenePhase = scenePhase
                    notifications.bootstrap()
                    if preferences.remotePushEnabled { notifications.registerForRemotePush() }
                }
        }
        .modelContainer(for: ServerConfig.self)
        .onChange(of: scenePhase) { _, phase in
            notifications.scenePhase = phase
            store.handleScenePhase(phase)
        }
    }
}
