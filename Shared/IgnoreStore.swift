import Foundation
import IRCCore

/// Per-server ignore lists (`/ignore`), kept on the device. IRC has no server-side
/// list every network supports, and a nick on one network isn't the same person
/// on another, so each server config has its own list.
///
/// Stored in the App Group's defaults so the Notification Service Extension can
/// keep pushes from ignored senders quiet too.
enum IgnoreStore {
    private static let prefix = "ignores."

    /// Shared with the extension; falls back to the app's own defaults if the
    /// App Group isn't available (e.g. an unsigned build).
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.im.arkhe.client") ?? .standard
    }

    static func load(_ id: UUID) -> [IgnoreMask] {
        migrateIfNeeded(id)
        return decode(defaults.data(forKey: key(id)))
    }

    static func save(_ masks: [IgnoreMask], for id: UUID) {
        if masks.isEmpty {
            delete(id)
        } else if let data = try? JSONEncoder().encode(masks) {
            defaults.set(data, forKey: key(id))
        }
    }

    static func delete(_ id: UUID) {
        defaults.removeObject(forKey: key(id))
        defaults.removeObject(forKey: syncedKey(id))
        UserDefaults.standard.removeObject(forKey: key(id))
    }

    /// The nicks (case-folded) that were blocked on the bouncer at the last
    /// `soju.im/blocked` sync — the common ancestor for the three-way merge on
    /// the next connect, which tells "unblocked elsewhere" from "blocked here".
    static func loadSynced(_ id: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: syncedKey(id)) ?? [])
    }

    static func saveSynced(_ nicks: Set<String>, for id: UUID) {
        defaults.set(nicks.sorted(), forKey: syncedKey(id))
    }

    /// Every server's rules together. A push doesn't say which server it came
    /// from (all share one Web Push key), so the extension checks them all.
    static func loadAll() -> [IgnoreMask] {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(prefix) }
            .flatMap { decode($0.value as? Data) }
    }

    /// Lists saved before the App Group store lived in the app's own defaults.
    private static func migrateIfNeeded(_ id: UUID) {
        let shared = defaults
        guard shared !== UserDefaults.standard, shared.data(forKey: key(id)) == nil,
              let old = UserDefaults.standard.data(forKey: key(id)) else { return }
        shared.set(old, forKey: key(id))
        UserDefaults.standard.removeObject(forKey: key(id))
    }

    private static func decode(_ data: Data?) -> [IgnoreMask] {
        guard let data, let masks = try? JSONDecoder().decode([IgnoreMask].self, from: data) else { return [] }
        return masks
    }

    private static func key(_ id: UUID) -> String { prefix + id.uuidString }
    // Deliberately outside `prefix`, so `loadAll()` doesn't read it as rules.
    private static func syncedKey(_ id: UUID) -> String { "ignoresync." + id.uuidString }
}
