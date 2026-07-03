import SwiftUI
import SwiftData

/// Top-level adaptive layout: a sidebar of servers/buffers and a chat detail.
/// `NavigationSplitView` gives the three-column iPad experience and collapses
/// to a stack on iPhone automatically.
struct RootView: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerConfig.sortOrder) private var servers: [ServerConfig]

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editingServer: ServerConfig?
    @State private var showingNewServer = false
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(servers: servers, editServer: { editingServer = $0 })
                .navigationTitle("Arkhe")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNewServer = true } label: {
                            Label("Add server", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        } detail: {
            if let session = store.selectedSession, let buffer = store.selectedBuffer {
                ChatView(session: session, buffer: buffer)
                    .id(buffer.id)
            } else {
                ContentUnavailableView(
                    "No conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Connect to a server or bouncer and pick a channel.")
                )
            }
        }
        .sheet(isPresented: $showingNewServer) {
            NavigationStack { ServerEditView(server: nil) }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $editingServer) { server in
            NavigationStack { ServerEditView(server: server) }
        }
        .task {
            // Auto-connect flagged servers on launch.
            for server in servers where server.autoConnect {
                store.connect(server)
            }
        }
    }
}
