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
    /// Keep recent scrollback on the device so conversations show instantly at
    /// launch. Turning it off deletes what was stored.
    var keepHistoryOnDevice: Bool {
        didSet {
            d.set(keepHistoryOnDevice, forKey: K.keepHistory)
            if !keepHistoryOnDevice { HistoryStore.deleteAll() }
        }
    }

    /// Local notifications for highlights and direct messages. `notificationsEnabled`
    /// is the master switch; the rest refine it.
    var notificationsEnabled: Bool     { didSet { d.set(notificationsEnabled, forKey: K.notifEnabled) } }
    var notifyOnMention: Bool          { didSet { d.set(notifyOnMention, forKey: K.notifMention) } }
    var notifyOnDirectMessage: Bool    { didSet { d.set(notifyOnDirectMessage, forKey: K.notifDM) } }
    /// Whether the alert shows the message text (off = "New message" only).
    var notificationPreviews: Bool     { didSet { d.set(notificationPreviews, forKey: K.notifPreview) } }
    var notificationSound: Bool        { didSet { d.set(notificationSound, forKey: K.notifSound) } }

    /// Extra words (besides your nick) that trigger a highlight and its alert.
    var highlightKeywords: [String]    { didSet { d.set(highlightKeywords, forKey: K.highlights) } }

    /// Conversations (channels or nicks, lowercased) muted from local alerts.
    /// Unread/mention state still updates in-app; only the notification is
    /// suppressed. Remote push (app closed) is decided by the bouncer and isn't
    /// affected. Managed via `setMuted`.
    private(set) var mutedConversations: Set<String>

    func isMuted(_ conversation: String) -> Bool {
        mutedConversations.contains(conversation.lowercased())
    }

    func setMuted(_ muted: Bool, for conversation: String) {
        let key = conversation.lowercased()
        if muted { mutedConversations.insert(key) } else { mutedConversations.remove(key) }
        d.set(Array(mutedConversations), forKey: K.muted)
    }

    /// Appends a trimmed keyword, ignoring blanks and case-insensitive duplicates.
    func addHighlightKeyword(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty,
              !highlightKeywords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame })
        else { return }
        highlightKeywords.append(w)
    }

    func removeHighlightKeywords(at offsets: IndexSet) {
        highlightKeywords = highlightKeywords.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
    }

    /// Remote push (via the bouncer's `soju.im/webpush` + a relay) so alerts
    /// arrive when the app is fully closed. Off by default.
    var remotePushEnabled: Bool        { didSet { d.set(remotePushEnabled, forKey: K.pushEnabled) } }
    /// The Web Push → APNs relay the app registers with soju. Default is the
    /// shared relay; self-hosters can point this at their own.
    var pushRelayURL: String           { didSet { d.set(pushRelayURL, forKey: K.pushRelay) } }

    /// A stable, per-install client name sent to soju as the `@client` username
    /// suffix. soju keeps a separate message buffer and replay cursor per client
    /// name, so this lets the bouncer replay exactly what *this device* missed on
    /// reconnect, independent of your other clients (desktop, etc.). Generated
    /// once and persisted; a fresh install gets a new one.
    let sojuClientName: String

    private let d = UserDefaults.standard

    private enum K {
        static let presence   = "pref.presenceVisibility"
        static let collapse   = "pref.collapseEvents"
        static let timestamps = "pref.showTimestamps"
        static let clock      = "pref.clockStyle"
        static let media      = "pref.autoLoadMedia"
        static let keepHistory = "pref.keepHistoryOnDevice"
        static let notifEnabled = "pref.notificationsEnabled"
        static let notifMention = "pref.notifyOnMention"
        static let notifDM      = "pref.notifyOnDirectMessage"
        static let notifPreview = "pref.notificationPreviews"
        static let notifSound   = "pref.notificationSound"
        static let highlights   = "pref.highlightKeywords"
        static let muted        = "pref.mutedConversations"
        static let pushEnabled  = "pref.remotePushEnabled"
        static let pushRelay    = "pref.pushRelayURL"
        static let clientName   = "pref.sojuClientName"
    }

    static let defaultRelayURL = "https://push.arkhe.priet.us"

    init() {
        // didSet does not fire for these initial assignments, so no redundant writes.
        presenceVisibility = PresenceVisibility(rawValue: d.string(forKey: K.presence) ?? "") ?? .show
        collapseEvents = d.object(forKey: K.collapse) as? Bool ?? false
        showTimestamps = d.object(forKey: K.timestamps) as? Bool ?? true
        clockStyle = ClockStyle(rawValue: d.string(forKey: K.clock) ?? "") ?? .system
        autoLoadMedia = d.object(forKey: K.media) as? Bool ?? true
        keepHistoryOnDevice = d.object(forKey: K.keepHistory) as? Bool ?? true
        notificationsEnabled = d.object(forKey: K.notifEnabled) as? Bool ?? true
        notifyOnMention = d.object(forKey: K.notifMention) as? Bool ?? true
        notifyOnDirectMessage = d.object(forKey: K.notifDM) as? Bool ?? true
        notificationPreviews = d.object(forKey: K.notifPreview) as? Bool ?? true
        notificationSound = d.object(forKey: K.notifSound) as? Bool ?? true
        highlightKeywords = d.stringArray(forKey: K.highlights) ?? []
        mutedConversations = Set(d.stringArray(forKey: K.muted) ?? [])
        remotePushEnabled = d.object(forKey: K.pushEnabled) as? Bool ?? false
        pushRelayURL = d.string(forKey: K.pushRelay) ?? Self.defaultRelayURL
        if let saved = d.string(forKey: K.clientName), !saved.isEmpty {
            sojuClientName = saved
        } else {
            let generated = "arkhe-" + UUID().uuidString.prefix(6).lowercased()
            d.set(generated, forKey: K.clientName)
            sojuClientName = generated
        }
    }
}
