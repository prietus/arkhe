import Foundation
import IRCCore

/// Per-server ignore lists (`/ignore`), kept on the device. IRC has no server-side
/// list every network supports, and a nick on one network isn't the same person
/// on another, so each server config has its own list.
enum IgnoreStore {
    static func load(_ id: UUID) -> [IgnoreMask] {
        guard let data = UserDefaults.standard.data(forKey: key(id)),
              let masks = try? JSONDecoder().decode([IgnoreMask].self, from: data) else { return [] }
        return masks
    }

    static func save(_ masks: [IgnoreMask], for id: UUID) {
        if masks.isEmpty {
            delete(id)
        } else if let data = try? JSONEncoder().encode(masks) {
            UserDefaults.standard.set(data, forKey: key(id))
        }
    }

    static func delete(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }

    private static func key(_ id: UUID) -> String { "ignores.\(id.uuidString)" }
}
