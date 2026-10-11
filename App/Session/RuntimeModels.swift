import Foundation
import Observation

/// A rendered line in a buffer. Value type — buffers hold an array of these.
struct ChatLine: Identifiable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
        case message      // PRIVMSG
        case notice       // NOTICE
        case action       // CTCP ACTION (/me)
        case event        // joins, parts, topic changes, mode, etc.
        case error        // server / client errors
        case motd

        /// Whether a line of this kind should count toward unread / read markers.
        var countsAsUnread: Bool {
            switch self {
            case .message, .notice, .action: return true
            case .event, .error, .motd: return false
            }
        }
    }

    /// Presence events that the user can choose to hide or collapse. Other
    /// `.event` lines (topic, mode, connection) carry `presence == nil` and are
    /// always shown.
    enum Presence: String, Sendable, Codable { case join, part, quit, nick }

    let id: UUID
    var timestamp: Date
    var sender: String?
    var text: String
    var kind: Kind
    var isSelf: Bool
    var account: String?
    /// IRCv3 `msgid` tag — stable server-assigned id. Used for chathistory
    /// pagination, reactions, replies and redaction.
    var msgid: String?
    /// `+draft/reply` — the msgid of the message this one replies to.
    var replyTo: String?
    /// `+draft/react` reactions: emoji → set of nicks who reacted.
    var reactions: [String: Set<String>]
    /// `draft/message-redaction`: set once the message has been deleted.
    var redacted: Bool
    var redactedBy: String?
    var redactionReason: String?
    /// For `.event` lines, the kind of presence change (join/part/quit/nick) so
    /// the UI can hide or collapse them; `nil` for non-presence events.
    var presence: Presence?
    /// The nick the presence event concerns — used by the "active users only"
    /// smart filter.
    var presenceNick: String?
    /// True when delivered from history (chathistory) rather than live.
    var isHistorical: Bool

    init(id: UUID = UUID(), timestamp: Date, sender: String?, text: String,
         kind: Kind, isSelf: Bool = false, account: String? = nil,
         msgid: String? = nil, replyTo: String? = nil,
         reactions: [String: Set<String>] = [:],
         redacted: Bool = false, redactedBy: String? = nil, redactionReason: String? = nil,
         presence: Presence? = nil, presenceNick: String? = nil,
         isHistorical: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.text = text
        self.kind = kind
        self.isSelf = isSelf
        self.account = account
        self.msgid = msgid
        self.replyTo = replyTo
        self.reactions = reactions
        self.redacted = redacted
        self.redactedBy = redactedBy
        self.redactionReason = redactionReason
        self.presence = presence
        self.presenceNick = presenceNick
        self.isHistorical = isHistorical
    }
}

/// A channel member with their highest membership prefix.
/// The messages around a reply's original, fetched on demand (CHATHISTORY
/// AROUND) because it predates the loaded scrollback.
struct AroundContext: Identifiable {
    var target: String
    /// The original message the user wants to see.
    var msgid: String
    var lines: [ChatLine] = []
    var isLoading = true
    /// The server couldn't return it (unsupported, deleted or too old).
    var failed = false
    /// Closed by the user while still loading: kept until its batch arrives so
    /// those messages are still routed here and not into the timeline.
    var dismissed = false
    var id: String { msgid }
}

struct Member: Identifiable, Sendable, Hashable {
    var nick: String
    var prefix: Character?    // @, +, etc. (highest)
    var account: String?
    /// Realname / gecos, from extended-join or a SETNAME change.
    var realname: String? = nil
    /// IRCv3 Bot Mode: the account is flagged as a bot.
    var isBot: Bool = false
    /// IRCv3 away-notify: the user is marked /away on the server.
    var isAway: Bool = false
    var id: String { nick }

    /// Sort key: ops first, then voiced, then by nick (case-insensitive).
    var sortRank: Int {
        switch prefix {
        case "~": return 0   // owner
        case "&": return 1   // admin
        case "@": return 2   // op
        case "%": return 3   // halfop
        case "+": return 4   // voice
        default: return 5
        }
    }
}

/// A conversation target: the server status window, a channel, or a private query.
@MainActor @Observable
final class Buffer: Identifiable {
    enum Kind: String, Sendable, Codable { case status, channel, query }

    let id = UUID()
    let name: String
    var kind: Kind
    var lines: [ChatLine] = []
    var topic: String?
    var members: [Member] = []
    /// Whether the member roster has been populated yet. With
    /// `no-implicit-names` the server doesn't push NAMES on JOIN, so the
    /// list is fetched lazily the first time the channel is viewed.
    var membersLoaded: Bool = false
    var unreadCount: Int = 0
    var hasMention: Bool = false
    var isJoined: Bool = false
    /// Whether scrollback has already been requested via chathistory.
    var loadedHistory: Bool = false
    /// Server-confirmed read boundary (draft/read-marker). Lines at or before
    /// this timestamp are considered read on every device sharing the bouncer.
    var readMarker: Date?
    /// A chathistory request for this buffer is in flight.
    var isLoadingHistory: Bool = false
    /// The server returned a short page — no older history remains.
    var historyExhausted: Bool = false
    /// Live typing state (+typing client tag): nick → last "active" instant.
    var typing: [String: Date] = [:]
    /// Server msgids already processed — lines shown AND stateful TAGMSGs
    /// (reactions) applied — so a duplicate delivery (reconnect catch-up overlap,
    /// event-playback replay, multi-batch) is dropped instead of applied twice.
    private var seenMsgIDs: Set<String> = []

    /// Records a msgid as processed. Returns false when it had already been
    /// seen — the caller should skip the message.
    func markProcessed(_ msgid: String) -> Bool {
        seenMsgIDs.insert(msgid).inserted
    }

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Seeds the buffer from on-device history (see `HistoryStore`), recording
    /// the msgids so the reconnect catch-up's overlap is dropped as duplicates.
    func restore(_ snapshot: HistoryStore.BufferSnapshot) {
        lines = snapshot.lines
        for case let mid? in snapshot.lines.map(\.msgid) { seenMsgIDs.insert(mid) }
        topic = snapshot.topic
        readMarker = snapshot.readMarker
        historyExhausted = snapshot.historyExhausted
        // Restored scrollback counts as already loaded: the next JOIN catches up
        // with `CHATHISTORY AFTER` instead of re-pulling the `LATEST` page.
        loadedHistory = !lines.isEmpty
        recomputeUnread()
    }

    /// Drops all scrollback so it can be re-fetched from scratch — used when a
    /// catch-up gap is too large to page through.
    func resetHistory() {
        lines.removeAll()
        seenMsgIDs.removeAll()
        loadedHistory = false
        historyExhausted = false
        unreadCount = 0
    }

    /// Timestamp of the newest real (msgid-bearing) message — the boundary a
    /// reconnect uses to catch up via `CHATHISTORY AFTER`.
    var newestMessageTimestamp: Date? {
        lines.last(where: { $0.msgid != nil })?.timestamp
    }

    var sortedMembers: [Member] {
        members.sorted {
            $0.sortRank != $1.sortRank
                ? $0.sortRank < $1.sortRank
                : $0.nick.lowercased() < $1.nick.lowercased()
        }
    }

    func append(_ line: ChatLine, markUnread: Bool) {
        // Drop anything we already hold, keyed on the stable server msgid: a
        // reconnect catch-up page overlaps what we have, event-playback can replay
        // a live line, and a message may be delivered under more than one batch.
        // Lines without a msgid (local status lines) always append.
        if let mid = line.msgid, !markProcessed(mid) { return }
        // History lines slot into timestamp order; live lines append. A history
        // page (LATEST/BEFORE) arrives oldest-first, so we insert before the
        // first strictly-newer line — this keeps each page a contiguous, ordered
        // block even when a live message landed mid-replay (otherwise everything
        // after the first history line would get appended to the very end).
        if line.isHistorical {
            let index = lines.firstIndex { $0.timestamp > line.timestamp } ?? lines.endIndex
            lines.insert(line, at: index)
        } else {
            lines.append(line)
        }
        if markUnread && !line.isHistorical {
            // Don't re-count something already behind the read marker.
            if let marker = readMarker, line.timestamp <= marker { return }
            unreadCount += 1
        }
    }

    /// Recomputes the unread count from the read marker — used when a marker
    /// arrives from another device or after a history page lands.
    func recomputeUnread() {
        guard let marker = readMarker else { return }
        let count = lines.filter {
            !$0.isSelf && $0.kind.countsAsUnread && $0.timestamp > marker
        }.count
        unreadCount = count
        if count == 0 { hasMention = false }
    }

    /// The first line past the read marker — where the "new messages" divider
    /// is drawn.
    var firstUnreadID: UUID? {
        guard let marker = readMarker else { return nil }
        return lines.first {
            !$0.isSelf && $0.kind.countsAsUnread && $0.timestamp > marker
        }?.id
    }

    /// Records a reaction against the line with `msgid`, if present.
    func addReaction(_ emoji: String, toMsgID msgid: String, from nick: String) {
        guard let index = lines.firstIndex(where: { $0.msgid == msgid }) else { return }
        lines[index].reactions[emoji, default: []].insert(nick)
    }

    /// Removes a reaction (`+draft/unreact`); drops the emoji entry once empty.
    func removeReaction(_ emoji: String, fromMsgID msgid: String, by nick: String) {
        guard let index = lines.firstIndex(where: { $0.msgid == msgid }) else { return }
        lines[index].reactions[emoji]?.remove(nick)
        if lines[index].reactions[emoji]?.isEmpty == true { lines[index].reactions[emoji] = nil }
    }

    /// Whether `nick` already reacted with `emoji` on the line with `msgid`.
    func hasReaction(_ emoji: String, onMsgID msgid: String, from nick: String) -> Bool {
        lines.first { $0.msgid == msgid }?.reactions[emoji]?.contains(nick) ?? false
    }

    /// Flags (or unflags) a member as a bot across this buffer's roster.
    func setBot(_ nick: String, _ value: Bool, equals: (String, String) -> Bool) {
        if let i = members.firstIndex(where: { equals($0.nick, nick) }) { members[i].isBot = value }
    }

    /// Marks (or clears) a member as away across this buffer's roster
    /// (IRCv3 away-notify).
    func setAway(_ nick: String, _ value: Bool, equals: (String, String) -> Bool) {
        if let i = members.firstIndex(where: { equals($0.nick, nick) }) { members[i].isAway = value }
    }

    /// Marks the message with `msgid` as redacted (draft/message-redaction).
    @discardableResult
    func redact(msgid: String, by nick: String?, reason: String?) -> Bool {
        guard let index = lines.firstIndex(where: { $0.msgid == msgid }) else { return false }
        lines[index].redacted = true
        lines[index].redactedBy = nick
        lines[index].redactionReason = reason
        return true
    }

    /// Nicks considered actively typing as of `now` (+typing expires after 6s).
    func currentlyTyping(asOf now: Date) -> [String] {
        typing.filter { now.timeIntervalSince($0.value) < 6 }
            .keys.sorted { $0.lowercased() < $1.lowercased() }
    }
}

/// A network advertised by a soju bouncer via `soju.im/bouncer-networks`.
struct BouncerNetwork: Identifiable, Sendable {
    var id: String              // network id assigned by the bouncer
    var name: String
    var state: String?          // connected / disconnected / connecting
    var host: String?
    var nickname: String?
    var attributes: [String: String]
}
