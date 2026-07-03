import Foundation
import Observation

/// User-facing display preferences, persisted in `UserDefaults`. Injected into
/// the environment so views react to changes automatically.
@MainActor
@Observable
final class Preferences {
    /// How to treat join / part / quit / nick-change lines in channels.
    enum PresenceVisibility: String, CaseIterable, Identifiable {
        case show       // every join/part/quit
        case smart      // only for users who've spoken recently
        case hide       // none

        var id: String { rawValue }
        var label: String {
            switch self {
            case .show:  return "Show all"
            case .smart: return "Active users only"
            case .hide:  return "Hide"
            }
        }
    }

    enum ClockStyle: String, CaseIterable, Identifiable {
        case system, twelveHour, twentyFourHour

        var id: String { rawValue }
        var label: String {
            switch self {
            case .system:        return "System"
            case .twelveHour:    return "12-hour"
            case .twentyFourHour: return "24-hour"
            }
        }
    }

    /// A nick counts as "active" for the smart filter if it has spoken within
    /// this window around the presence event.
    static let activeWindow: TimeInterval = 600   // 10 minutes

    var presenceVisibility: PresenceVisibility { didSet { d.set(presenceVisibility.rawValue, forKey: K.presence) } }
    var collapseEvents: Bool                    { didSet { d.set(collapseEvents, forKey: K.collapse) } }
    var showTimestamps: Bool                    { didSet { d.set(showTimestamps, forKey: K.timestamps) } }
    var clockStyle: ClockStyle                  { didSet { d.set(clockStyle.rawValue, forKey: K.clock) } }
    /// Auto-fetch inline image thumbnails and link previews. URLs are always
    /// tappable regardless; this only governs automatic network fetches (which
    /// reveal your IP to the link's host — an IRC privacy consideration).
    var autoLoadMedia: Bool                     { didSet { d.set(autoLoadMedia, forKey: K.media) } }

    private let d = UserDefaults.standard

    private enum K {
        static let presence   = "pref.presenceVisibility"
        static let collapse   = "pref.collapseEvents"
        static let timestamps = "pref.showTimestamps"
        static let clock      = "pref.clockStyle"
        static let media      = "pref.autoLoadMedia"
    }

    init() {
        // didSet does not fire for these initial assignments, so no redundant writes.
        presenceVisibility = PresenceVisibility(rawValue: d.string(forKey: K.presence) ?? "") ?? .show
        collapseEvents = d.object(forKey: K.collapse) as? Bool ?? false
        showTimestamps = d.object(forKey: K.timestamps) as? Bool ?? true
        clockStyle = ClockStyle(rawValue: d.string(forKey: K.clock) ?? "") ?? .system
        autoLoadMedia = d.object(forKey: K.media) as? Bool ?? true
    }
}
