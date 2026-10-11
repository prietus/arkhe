import Foundation

/// On-device scrollback: one JSON snapshot per server in Application Support,
/// so a cold launch shows conversations instantly instead of waiting for the
/// network. The bouncer stays the source of truth — on reconnect the session
/// catches up with `CHATHISTORY AFTER` the newest restored message, and msgid
/// dedup drops the overlap.
enum HistoryStore {
    /// Lines kept per buffer; older ones are paged back in from the server.
    static let maxLinesPerBuffer = 500

    struct Snapshot: Codable {
        var version = 1
        var buffers: [BufferSnapshot]
    }

    struct BufferSnapshot: Codable {
        var name: String
        var kind: Buffer.Kind
        var topic: String?
        var readMarker: Date?
        var historyExhausted: Bool
        var lines: [ChatLine]
    }

    static func load(_ id: UUID) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: id)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return nil }
        return snapshot
    }

    /// Encodes on the caller (cheap, and keeps main-actor state on main) and
    /// writes atomically off the main thread.
    static func save(_ snapshot: Snapshot, for id: UUID) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = fileURL(for: id)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "History", directoryHint: .isDirectory)
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
