import Foundation

/// The user's own profile (draft/metadata-2 keys such as display name, pronouns,
/// avatar), kept per server: metadata lives on each network separately. Stored
/// on the device and re-published on every connect, so it persists even where
/// the server forgets it between connections.
enum ProfileStore {
    static func load(_ id: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(id)) as? [String: String] ?? [:]
    }

    static func save(_ profile: [String: String], for id: UUID) {
        UserDefaults.standard.set(profile, forKey: key(id))
    }

    /// Keys we've published on this server, so one emptied while offline is
    /// cleared there on the next connect.
    static func loadPublished(_ id: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: publishedKey(id)) ?? [])
    }

    static func savePublished(_ keys: Set<String>, for id: UUID) {
        UserDefaults.standard.set(keys.sorted(), forKey: publishedKey(id))
    }

    static func delete(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
        UserDefaults.standard.removeObject(forKey: publishedKey(id))
    }

    private static func key(_ id: UUID) -> String { "profile.\(id.uuidString)" }
    private static func publishedKey(_ id: UUID) -> String { "profilepub.\(id.uuidString)" }
}
