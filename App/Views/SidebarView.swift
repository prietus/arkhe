import SwiftUI
import SwiftData

/// The server/buffer list. One section per configured server, each showing a
/// connection control and its open buffers.
struct SidebarView: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let servers: [ServerConfig]
    let editServer: (ServerConfig) -> Void

    var body: some View {
        List(selection: bufferSelection) {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No servers",
                    systemImage: "server.rack",
                    description: Text("Tap + to add an IRC server or a soju bouncer.")
                )
            }
            ForEach(servers) { server in
                ServerSection(server: server, editServer: editServer)
            }
        }
        .listStyle(.sidebar)
    }

    private var bufferSelection: Binding<UUID?> {
        Binding(
            get: { store.selectedBufferID },
            set: { newValue in
                // Always resolve the session that actually owns this buffer. Don't
                // prefer the currently-selected session — picking a channel in a
                // second network would otherwise resolve against the wrong session,
                // find no matching buffer, and silently do nothing.
                guard let id = newValue,
                      let session = store.sessions.values.first(where: { s in
                          s.buffers.contains { $0.id == id }
                      }),
                      let buffer = session.buffers.first(where: { $0.id == id }) else { return }
                store.select(buffer, in: session)
            }
        )
    }
}

private struct ServerSection: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    let server: ServerConfig
    let editServer: (ServerConfig) -> Void

    private var session: IRCSession? { store.sessions[server.id] }
    private var openedNetworks: [IRCSession] { store.networkSessions[server.id] ?? [] }
    private var unopenedNetworks: [BouncerNetwork] {
        let opened = Set(openedNetworks.compactMap(\.boundNetworkID))
        return (session?.bouncerNetworks ?? []).filter { !opened.contains($0.id) }
    }

    var body: some View {
        Group {
            // The account / control connection.
            Section {
                if let session { buffers(of: session) }
                ForEach(unopenedNetworks) { network in
                    Button { store.openNetwork(network, from: server) } label: {
                        Label(network.name, systemImage: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                accountHeader
            }

            // One section per opened bound network.
            ForEach(openedNetworks) { netSession in
                Section {
                    buffers(of: netSession)
                } header: {
                    networkHeader(netSession)
                }
            }
        }
    }

    @ViewBuilder private func buffers(of session: IRCSession) -> some View {
        ForEach(session.buffers) { buffer in
            BufferRow(buffer: buffer)
                .tag(buffer.id)
                .swipeActions {
                    if buffer.kind != .status {
                        Button(role: .destructive) {
                            session.part(buffer)
                        } label: { Label("Close", systemImage: "xmark") }
                    }
                }
        }
    }

    private var accountHeader: some View {
        HStack {
            statusDot(session)
            Text(server.name.isEmpty ? server.host : server.name)
                .font(.headline)
            Spacer()
            connectionButton
            Menu {
                Button { editServer(server) } label: { Label("Edit", systemImage: "pencil") }
                if session?.hasBouncerNetworks == true {
                    Label("soju bouncer active", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button(role: .destructive) { deleteServer() } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .textCase(nil)
    }

    private func networkHeader(_ session: IRCSession) -> some View {
        HStack(spacing: 6) {
            statusDot(session)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(.secondary)
            Text(session.config.name)
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                if session.status.isActive { session.disconnect() } else { session.connect() }
            } label: {
                Image(systemName: session.status.isActive ? "stop.circle" : "play.circle")
            }
        }
        .textCase(nil)
    }

    @ViewBuilder private var connectionButton: some View {
        switch session?.status {
        case .some(let status) where status.isActive:
            Button { store.disconnect(server) } label: {
                Image(systemName: "stop.circle")
            }
        default:
            Button { store.connect(server) } label: {
                Image(systemName: "play.circle")
            }
        }
    }

    private func statusDot(_ session: IRCSession?) -> some View {
        Circle()
            .fill(statusColor(session))
            .frame(width: 9, height: 9)
    }

    private func statusColor(_ session: IRCSession?) -> Color {
        switch session?.status {
        case .connected: return .green
        case .connecting, .registering: return .yellow
        case .failed: return .red
        default: return .secondary
        }
    }

    private func deleteServer() {
        store.removeSession(server.id)
        modelContext.delete(server)
    }
}

private struct BufferRow: View {
    @Environment(Preferences.self) private var prefs
    let buffer: Buffer

    private var isMuted: Bool { prefs.isMuted(buffer.name) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(buffer.isJoined || buffer.kind != .channel ? .primary : .secondary)
                .frame(width: 18)
            Text(buffer.name)
                .lineLimit(1)
            Spacer()
            if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if buffer.unreadCount > 0 {
                Text("\(buffer.unreadCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(buffer.hasMention && !isMuted ? Color.red : Color.secondary.opacity(0.3),
                                in: Capsule())
                    .foregroundStyle(buffer.hasMention && !isMuted ? .white : .primary)
            }
        }
        .contextMenu {
            if buffer.kind != .status {
                Button {
                    prefs.setMuted(!isMuted, for: buffer.name)
                } label: {
                    Label(isMuted ? "Unmute" : "Mute",
                          systemImage: isMuted ? "bell" : "bell.slash")
                }
            }
        }
    }

    private var icon: String {
        switch buffer.kind {
        case .status: return "bolt.horizontal.circle"
        case .channel: return "number"
        case .query: return "person"
        }
    }
}
