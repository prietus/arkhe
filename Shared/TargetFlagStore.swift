import Foundation

/// Per-server conversation flags — muted and pinned channels/queries — keyed by
/// lowercased name. Kept in the App Group's defaults so the notification
/// extension can quiet pushes for muted conversations too. On a soju bouncer
/// they're mirrored to `soju.im/muted` / `soju.im/pinned`.
enum TargetFlag: String, CaseIterable, Sendable {
    case muted, pinned
}

enum TargetFlagStore {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.im.arkhe.client") ?? .standard
    }

    static func load(_ flag: TargetFlag, _ id: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: key(flag, id)) ?? [])
    }

    static func save(_ names: Set<String>, _ flag: TargetFlag, _ id: UUID) {
        defaults.set(names.sorted(), forKey: key(flag, id))
    }

    /// Whether `name` carries `flag` on any server — for a push, which doesn't
    /// say which server it came from.
    static func anyServer(_ flag: TargetFlag, contains name: String) -> Bool {
        let wanted = name.lowercased()
        let prefix = "flags.\(flag.rawValue)."
        return defaults.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(prefix) && ((value as? [String])?.contains(wanted) ?? false)
        }
    }

    /// Mutes used to be one global list; seed a server with it the first time
    /// so upgrading doesn't silently unmute anything.
    static func seedIfAbsent(_ flag: TargetFlag, _ id: UUID, with names: Set<String>) {
        guard defaults.object(forKey: key(flag, id)) == nil, !names.isEmpty else { return }
        save(Set(names.map { $0.lowercased() }), flag, id)
    }

    /// The flagged names at the last soju sync, for the three-way merge.
    static func loadSynced(_ flag: TargetFlag, _ id: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: syncedKey(flag, id)) ?? [])
    }

    static func saveSynced(_ names: Set<String>, _ flag: TargetFlag, _ id: UUID) {
        defaults.set(names.sorted(), forKey: syncedKey(flag, id))
    }

    static func delete(_ id: UUID) {
        for flag in TargetFlag.allCases {
            defaults.removeObject(forKey: key(flag, id))
            defaults.removeObject(forKey: syncedKey(flag, id))
        }
    }

    private static func key(_ flag: TargetFlag, _ id: UUID) -> String { "flags.\(flag.rawValue).\(id.uuidString)" }
    private static func syncedKey(_ flag: TargetFlag, _ id: UUID) -> String { "flagsync.\(flag.rawValue).\(id.uuidString)" }
}
