import SwiftUI
import SwiftData

@main
struct ArkheApp: App {
    @State private var store = ClientStore()
    @State private var preferences = Preferences()
    @State private var uploader = UploaderSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(preferences)
                .environment(uploader)
        }
        .modelContainer(for: ServerConfig.self)
    }
}
