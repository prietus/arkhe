import Foundation
import Observation
import IRCCore

/// Drives one live connection: runs registration (CAP/SASL), dispatches inbound
/// messages into buffers, and exposes observable state to SwiftUI. One
/// `IRCSession` maps to one `ServerConfig` (a direct network or a soju bouncer).
@MainActor
@Observable
final class IRCSession: Identifiable {
    enum Status: Equatable, Sendable {
        case offline
        case connecting
        case registering
        case connected
        case failed(String)

        var isActive: Bool {
            switch self {
            case .connecting, .registering, .connected: return true
            default: return false
            }
        }
    }

    let id: UUID
    private(set) var config: SessionConfig

    private(set) var status: Status = .offline
    private(set) var currentNick: String
    private(set) var isupport = ISupport()
    private(set) var enabledCaps: Set<String> = []
    private(set) var saslMessage: String?

    /// Emitted when an inbound message deserves a user notification: a highlight
    /// (your nick mentioned in a channel) or a direct message. Wired by
    /// `ClientStore` to the app's `NotificationManager`.
    var onNotifiableEvent: ((NotifiableEvent) -> Void)?

    /// User-defined highlight words (besides the nick). Supplied as a closure so
    /// it always reflects current preferences; a message containing any of these
    /// (case-insensitive) counts as a mention. Wired by `ClientStore`.
    var highlightKeywords: () -> [String] = { [] }

    /// Whether the user wants this session connected. Set on `connect()`, cleared
    /// on an explicit `disconnect()`, so the app can re-dial after iOS drops the
    /// socket during suspension without reviving sessions the user closed.
    private(set) var wantsConnection = false

    /// All buffers, status window first.
    private(set) var buffers: [Buffer]
    let statusBuffer: Buffer

    /// Raw protocol console for this session (debug).
    let protocolLog = ProtocolLog()

    /// Networks advertised by a soju bouncer (when `bouncer-networks` is active).
    private(set) var bouncerNetworks: [BouncerNetwork] = []
    var hasBouncerNetworks: Bool { enabledCaps.contains(CapabilityName.bouncerNetworks) }
    /// The soju network this session is bound to, if it's a network sub-session.
    var boundNetworkID: String? { config.boundNetworkID }

    /// Whether the connected bouncer offers Web Push (`soju.im/webpush`).
    /// soju's `soju.im/webpush` or the IRCv3 `draft/webpush` (Ergo offers both).
    var supportsWebPush: Bool {
        isAuthenticated
            && (enabledCaps.contains(CapabilityName.webpush) || enabledCaps.contains(CapabilityName.draftWebpush))
    }

    /// Invoked once negotiation finishes and the bouncer supports Web Push, so
    /// the app can register a push subscription. Wired by `ClientStore`.
    var onWebPushReady: (() -> Void)?

    /// Whether this network relays reaction tags between users (`CLIENTTAGDENY`).
    /// When false, reactions are only ever seen on your own devices.
    var networkAllowsReactions: Bool { isupport.allowsClientTag("draft/react") }
    /// Whether reply-linkage tags cross to other users. The text always sends;
    /// only the threading tag may be stripped.
    var networkAllowsReplies: Bool { isupport.allowsClientTag("draft/reply") }
    private var didWarnClientTagDeny = false

    /// The server's own upload endpoint (`draft/FILEHOST` / `soju.im/FILEHOST`),
    /// with the HTTP Basic credentials the spec asks for under SASL PLAIN. Plain
    /// http is only accepted when the IRC link itself isn't TLS.
    var fileHost: FileHostTarget? {
        guard status == .connected,
              let url = isupport.fileHost(allowInsecure: !config.useTLS) else { return nil }
        var target = FileHostTarget(url: url)
        if config.saslMode == .plain, let password = config.saslPassword {
            target.basicUser = config.saslAccount
            target.basicPassword = password
        }
        return target
    }

    private let connection: any IRCTransport
    private var negotiator: CapabilityNegotiator
    private var didCaptureCaps = false
    private var eventTask: Task<Void, Never>?
    private var bufferIndex: [String: Buffer] = [:]   // folded name → buffer
    private var openBatches: [String: BatchInfo] = [:]
    /// When we last sent `+typing=active` per buffer (folded), to throttle.
    private var typingState: [String: Date] = [:]
    /// labeled-response: outstanding command labels → human description, so a
    /// labelled reply (FAIL/ACK/…) can be tied back to what triggered it.
    private var labelCounter = 0
    private var pendingLabels: [String: String] = [:]
    /// Open `labeled-response` batches: batch ref → its label.
    private var labeledBatches: [String: String] = [:]
    /// Channels with a reconnect catch-up (`CHATHISTORY AFTER`) request in flight,
    /// so its incoming batch can be told apart from an initial/scroll-up page.
    private var catchUpTargets: Set<String> = []
    /// Set once this connection has seen a `draft/chathistory-end` tag. From then
    /// on a short page no longer implies "start of history": only the tag or an
    /// empty page does (Ergo may return short pages mid-history).
    private var serverSignalsHistoryEnd = false

    private struct BatchInfo {
        var type: String
        var target: String?
        var isHistory: Bool
        var messageCount: Int = 0
        /// A reconnect catch-up page (`CHATHISTORY AFTER` our newest message),
        /// not an initial `LATEST` or a scroll-up `BEFORE`. A short catch-up page
        /// means "we're up to date", NOT "reached the start", so it must not set
        /// `historyExhausted`.
        var isCatchUp: Bool = false
        /// The server flagged this page as the last one (`draft/chathistory-end`
        /// on the opening BATCH).
        var isEndOfHistory: Bool = false
        /// The batch answers our `CHATHISTORY AROUND`: its messages go to
        /// `aroundContext`, not into the buffer.
        var isAroundContext: Bool = false
        /// The enclosing batch (e.g. a chathistory batch a multiline sits in).
        var parentRef: String?
        // draft/multiline accumulation: the message's whole-message tags/source
        // ride on the opening BATCH; the parts are joined here.
        var multilineSource: IRCSource?
        var multilineTags: [String: String] = [:]
        var multilineText: String = ""
        var multilineHasContent: Bool = false
    }

    /// Monotonic counter for our outgoing multiline batch references.
    private var multilineBatchCounter = 0

    /// How many messages we ask for per chathistory page.
    private static let historyPageSize = 100
    /// Reconnect catch-up pages to chase before giving up on bridging the gap
    /// and re-fetching the latest page instead (avoids a hole in the middle).
    private static let maxCatchUpPages = 10
    /// Catch-up pages fetched so far per buffer name, during one catch-up run.
    private var catchUpPages: [String: Int] = [:]

    /// Messages around a reply's original that isn't in the loaded scrollback,
    /// fetched with `CHATHISTORY AROUND` and shown apart from the timeline (so
    /// no disconnected island lands in it). `nil` when nothing is requested.
    private(set) var aroundContext: AroundContext?
    /// The `AROUND` request is sent; its chathistory batch hasn't opened yet.
    private var aroundAwaitingBatch = false
    /// Paging back through a buffer looking for a reply's original, on servers
    /// that only take timestamp references (soju) and so can't do AROUND by msgid.
    private var originalSeek: (bufferKey: String, bufferName: String, msgid: String, pagesLeft: Int)?
    private static let maxSeekPages = 5

    /// A line the chat view should scroll to (a reply's original, found by
    /// paging back). The view consumes it with `consumeJump()`.
    struct JumpRequest: Equatable {
        var bufferID: UUID
        var lineID: UUID
    }
    private(set) var jumpRequest: JumpRequest?

    /// Client-side ignores (`/ignore`) for this server, persisted per config.
    private(set) var ignores: [IgnoreMask] = []

    /// Muted and pinned conversations on this server (lowercased names),
    /// persisted per config. Muting only silences notifications.
    private(set) var mutedTargets: Set<String> = []
    private(set) var pinnedTargets: Set<String> = []

    // On a soju bouncer, exact-nick ignores, mutes and pins are mirrored to its
    // per-target metadata (`soju.im/blocked`, `soju.im/muted`, `soju.im/pinned`
    // over draft/metadata-2), so they follow the user to other clients, and
    // soju itself drops a blocked nick's messages and pushes (and a muted
    // nick's pushes). Masks and accounts have no equivalent and stay local.
    private static let syncedMetadataKeys = [CapabilityName.sojuBlocked, CapabilityName.sojuMuted,
                                             CapabilityName.sojuPinned]
    /// Keys whose `METADATA * SUB` is out; collecting soju's current state.
    private var metadataSyncing: Set<String> = []
    /// Keys whose initial state is merged; changes now flow both ways live.
    private var metadataActive: Set<String> = []
    /// Per key: normalized target → target, as soju reports them while syncing.
    private var metadataServerState: [String: [String: String]] = [:]
    /// Per key: normalized targets flagged on soju at the last sync (persisted)
    /// — the common ancestor of the three-way merge on connect.
    private var metadataSynced: [String: Set<String>] = [:]

    /// Nicks (folded) currently on the server's MONITOR list, and whether we've
    /// started monitoring on this connection (after registration ends).
    private var monitored: Set<String> = []
    private var monitorStarted = false

    /// Other users' profile metadata (draft/metadata-2) — avatar, display name,
    /// pronouns — keyed by folded nick. Read-only: we don't publish our own.
    private(set) var userMetadata: [String: [String: String]] = [:]
    static let userMetadataKeys = ["avatar", "display-name", "pronouns"]

    func metadata(for nick: String) -> [String: String] {
        userMetadata[isupport.caseMapping.fold(nick)] ?? [:]
    }

    /// An `avatar` that's a usable http(s) URL.
    func avatarURL(for nick: String) -> URL? {
        guard let raw = metadata(for: nick)["avatar"], let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// The server is soju. It always offers `soju.im/bouncer-networks` (even
    /// when we don't take it on a bound connection); any `soju.im/` cap won't
    /// do — Ergo offers `soju.im/webpush` too.
    private var isSoju: Bool {
        negotiator.available.contains { $0.name == CapabilityName.bouncerNetworks }
    }

    /// We're logged in to an account (SASL, or a later RPL_LOGGEDIN): servers
    /// only take a Web Push subscription then — Ergo FAILs it otherwise.
    private(set) var isAuthenticated = false

    /// The initial soju metadata sync has finished for every key.
    var isMetadataSynced: Bool { metadataSyncing.isEmpty && !metadataActive.isEmpty }

    /// soju, on a connection bound to one network (soju keeps metadata per
    /// network; the multi-network connection rejects it).
    private var canSyncMetadata: Bool {
        enabledCaps.contains(CapabilityName.metadata) && config.isExplicitlyBound
            && isSoju
    }

    /// Whether CHATHISTORY takes `msgid=` references here (`MSGREFTYPES`).
    /// soju only takes timestamps and FAILs a msgid bound.
    private var acceptsMsgidReferences: Bool {
        isupport.messageReferenceTypes.contains("msgid")
    }

    /// WHOX query-type token echoed back in the `t` field, so we only act on WHO
    /// replies we asked for (not ones triggered by a user `/whois`).
    private static let whoxToken = "742"

    private static let timeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(config: SessionConfig, transport: any IRCTransport = IRCConnection()) {
        self.connection = transport
        self.id = config.id
        self.config = config
        self.currentNick = config.nickname
        self.negotiator = CapabilityNegotiator(desired: config.desiredCaps, mechanism: config.saslMechanism)
        self.ignores = IgnoreStore.load(config.id)
        self.mutedTargets = TargetFlagStore.load(.muted, config.id)
        self.pinnedTargets = TargetFlagStore.load(.pinned, config.id)
        self.metadataSynced = [
            CapabilityName.sojuBlocked: IgnoreStore.loadSynced(config.id),
            CapabilityName.sojuMuted: TargetFlagStore.loadSynced(.muted, config.id),
            CapabilityName.sojuPinned: TargetFlagStore.loadSynced(.pinned, config.id),
        ]
        let status = Buffer(name: config.name.isEmpty ? config.host : config.name, kind: .status)
        self.statusBuffer = status
        self.buffers = [status]
        self.bufferIndex["*"] = status
    }

    // MARK: - Lifecycle

    /// Replaces the connection-settings snapshot taken at init. Ignored while a
    /// connection is live so an in-flight session isn't yanked; used to pick up
    /// edits (host/port/TLS/identity) made in server settings before
    /// reconnecting — otherwise a reused session would dial the old address.
    func refreshConfig(_ newConfig: SessionConfig) {
        guard !status.isActive else { return }
        config = newConfig
        currentNick = newConfig.nickname
        negotiator = CapabilityNegotiator(desired: newConfig.desiredCaps, mechanism: newConfig.saslMechanism)
    }

    func connect() {
        wantsConnection = true
        guard !status.isActive else { return }
        status = .connecting
        didCaptureCaps = false
        didWarnClientTagDeny = false
        serverSignalsHistoryEnd = false
        metadataSyncing = []
        metadataActive = []
        metadataServerState = [:]
        isAuthenticated = false
        monitored = []
        monitorStarted = false
        negotiator = CapabilityNegotiator(desired: config.desiredCaps, mechanism: config.saslMechanism)
        addStatus("Connecting to \(config.host):\(config.port)…", kind: .event)

        eventTask = Task { [weak self] in
            await self?.runEventLoop()
        }
    }

    func disconnect(message: String = "Arkhe") {
        wantsConnection = false
        Task { await connection.send(.quit(message)) }
        Task { await connection.disconnect() }
        eventTask?.cancel()
        status = .offline
        for buffer in buffers { buffer.isJoined = false }
    }

    /// Re-dials if the user wanted this session up but the socket has since died
    /// (e.g. iOS tore it down while the app was suspended). No-op otherwise; on
    /// reconnect, chathistory replays whatever the bouncer buffered.
    func reconnectIfDropped() {
        guard wantsConnection, !status.isActive else { return }
        addStatus("Reconnecting…", kind: .event)
        connect()
    }

    private func runEventLoop() async {
        let endpoint: IRCConnection.Endpoint
        do {
            endpoint = try makeEndpoint()
        } catch {
            status = .failed(error.localizedDescription)
            addStatus("⚠️ \(error.localizedDescription)", kind: .error)
            return
        }

        let stream = await connection.open(endpoint)
        for await event in stream {
            switch event {
            case .connecting:
                status = .connecting
            case .ready:
                status = .registering
                await beginRegistration()
            case let .message(message):
                handle(message)
            case let .raw(line, outgoing):
                protocolLog.append(line, outgoing: outgoing)
            case let .error(text):
                addStatus("⚠️ \(text)", kind: .error)
            case .closed:
                status = .offline
                addStatus("Connection closed.", kind: .event)
                for buffer in buffers { buffer.isJoined = false }
            }
        }
    }

    private func makeEndpoint() throws -> IRCConnection.Endpoint {
        var identity: TLSIdentity?
        if config.saslMode == .external || config.certificateData != nil,
           let data = config.certificateData {
            identity = try TLSIdentity(pkcs12: data, passphrase: config.certificatePassphrase ?? "")
        }
        return IRCConnection.Endpoint(
            host: config.host,
            port: config.port,
            useTLS: config.useTLS,
            allowInvalidCertificates: config.allowInvalidCertificates,
            clientIdentity: identity
        )
    }

    private func beginRegistration() async {
        if let password = config.serverPassword, !password.isEmpty {
            await connection.send(.pass(password))
        }
        for message in negotiator.start() {
            await connection.send(message)
        }
        await connection.send(.nick(config.nickname))
        await connection.send(.user(config.username, realName: config.realName))
    }

    // MARK: - Sending

    func send(_ message: IRCMessage) {
        Task { await connection.send(message) }
    }

    /// Sends user-typed text. A leading `/` runs a command (`//` escapes it to a
    /// literal message); otherwise it's a PRIVMSG with an optional `+reply` tag.
    func sendText(_ text: String, to buffer: Buffer, replyingTo replyLine: ChatLine? = nil) {
        guard !text.isEmpty else { return }
        if text.hasPrefix("/"), !text.hasPrefix("//") {
            runCommand(text, in: buffer)
            return
        }

        let body = text.hasPrefix("//") ? String(text.dropFirst()) : text
        guard buffer.kind != .status else {
            addStatus("You can't message the status window. Try /join #channel.", kind: .error)
            return
        }
        sendMessage(body, to: buffer, replyTo: replyLine?.msgid)
        stopTyping(buffer)
    }

    /// Sends a PRIVMSG (with optional reply tag) and echoes locally. A message
    /// with embedded newlines goes out as a `draft/multiline` batch when the
    /// network supports it, otherwise as one PRIVMSG per line.
    private func sendMessage(_ body: String, to buffer: Buffer, replyTo: String? = nil) {
        var tags: [String: String] = [:]
        // Send both the ratified `+reply` and the legacy `+draft/reply`: the
        // deployed ecosystem (goguma et al.) still keys on the draft name, while
        // spec-compliant clients read `+reply`. A few extra bytes buys interop
        // with both during the transition.
        if let replyTo { tags["+reply"] = replyTo; tags["+draft/reply"] = replyTo }

        if body.contains("\n") {
            if enabledCaps.contains(CapabilityName.multiline) {
                sendMultiline(body, to: buffer, tags: tags)
            } else {
                for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    send(IRCMessage(tags: tags, command: "PRIVMSG", parameters: [buffer.name, String(line)]))
                }
                echoIfNeeded(body, to: buffer, kind: .message, replyTo: replyTo)
            }
            return
        }
        send(IRCMessage(tags: tags, command: "PRIVMSG", parameters: [buffer.name, body]))
        echoIfNeeded(body, to: buffer, kind: .message, replyTo: replyTo)
    }

    /// Emits a `draft/multiline` batch: whole-message tags ride on the opening
    /// BATCH, then one PRIVMSG per line (joined by newline on the far side).
    private func sendMultiline(_ body: String, to buffer: Buffer, tags: [String: String]) {
        multilineBatchCounter += 1
        let ref = "ml\(multilineBatchCounter)"
        send(IRCMessage(tags: tags, command: "BATCH",
                        parameters: ["+\(ref)", CapabilityName.multiline, buffer.name]))
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            send(IRCMessage(tags: ["batch": ref], command: "PRIVMSG",
                            parameters: [buffer.name, String(line)]))
        }
        send(.batchClose(ref))
        echoIfNeeded(body, to: buffer, kind: .message, replyTo: tags["+reply"])
    }

    /// Resolves the buffer to reply into from a notification: an existing channel
    /// we're in, or a (opened-on-demand) private query. Returns nil for a channel
    /// we've since left.
    func replyTarget(named name: String, isChannel: Bool) -> Buffer? {
        isChannel ? buffer(named: name, kind: .channel, createIfMissing: false)
                  : openQuery(name)
    }

    /// Sends `text` as a plain message (no slash-command parsing) — used for quick
    /// replies typed into a notification. Returns false if we can't send yet.
    @discardableResult
    func sendQuickReply(_ text: String, to buffer: Buffer) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, buffer.kind != .status, status == .connected else { return false }
        sendMessage(body, to: buffer)
        stopTyping(buffer)
        return true
    }

    /// Parses and runs a `/command`. Unknown commands are reported in status.
    private func runCommand(_ text: String, in buffer: Buffer) {
        let body = text.dropFirst()
        let split = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = split.first.map { String($0).lowercased() } ?? ""
        let rest = split.count > 1 ? String(split[1]) : ""

        switch cmd {
        case "join", "j":
            let channels = rest.split(separator: " ").first.map(String.init) ?? ""
            guard !channels.isEmpty else { addStatus("Usage: /join #channel", kind: .error); return }
            for channel in channels.split(separator: ",") { join(String(channel)) }

        case "part", "leave":
            let target = rest.isEmpty ? buffer.name : String(rest.split(separator: " ").first ?? "")
            if isupport.isChannel(target) { send(.part(target)) }
            if let b = self.buffer(named: target, kind: .channel, createIfMissing: false) { removeBuffer(b) }

        case "me":
            guard buffer.kind != .status, !rest.isEmpty else { return }
            send(.privmsg(buffer.name, "\u{01}ACTION \(rest)\u{01}"))
            echoIfNeeded(rest, to: buffer, kind: .action)
            stopTyping(buffer)

        case "msg":
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { addStatus("Usage: /msg <target> <message>", kind: .error); return }
            let kind: Buffer.Kind = isupport.isChannel(parts[0]) ? .channel : .query
            if let b = self.buffer(named: parts[0], kind: kind, createIfMissing: true) {
                sendMessage(parts[1], to: b)
            }

        case "query":
            guard let nick = rest.split(separator: " ").first.map(String.init) else { return }
            openQuery(nick)

        case "nick":
            guard !rest.isEmpty else { return }
            send(.nick(String(rest.split(separator: " ").first ?? "")))

        case "setname":
            guard !rest.isEmpty else { addStatus("Usage: /setname <real name>", kind: .error); return }
            send(.setname(rest))

        case "topic":
            guard buffer.kind == .channel else { addStatus("Use /topic in a channel.", kind: .error); return }
            send(IRCMessage(command: "TOPIC", parameters: rest.isEmpty ? [buffer.name] : [buffer.name, rest]))

        case "names":
            if buffer.kind == .channel { send(.names(buffer.name)) }

        case "whois":
            guard !rest.isEmpty else { return }
            send(IRCMessage(command: "WHOIS", parameters: [String(rest.split(separator: " ").first ?? "")]))

        case "quit":
            disconnect(message: rest.isEmpty ? "Arkhe" : rest)

        case "ignore":
            guard !rest.isEmpty else {
                note(ignores.isEmpty ? "Nobody is ignored on this server."
                     : "Ignored: " + ignores.map(\.pattern).joined(separator: ", "), in: buffer)
                return
            }
            guard let mask = IgnoreMask(parsing: rest) else {
                addStatus("Usage: /ignore <nick | nick!user@host | $a:account>", kind: .error); return
            }
            note(ignore(mask) ? "Ignoring \(mask)." : "Already ignoring \(mask).", in: buffer)

        case "unignore":
            guard let mask = IgnoreMask(parsing: rest) else {
                addStatus("Usage: /unignore <nick | mask>", kind: .error); return
            }
            note(unignore(mask) ? "No longer ignoring \(mask)." : "\(mask) isn't ignored.", in: buffer)

        case "invite":
            let parts = rest.split(separator: " ").map(String.init)
            let channel = parts.count > 1 ? parts[1] : (buffer.kind == .channel ? buffer.name : nil)
            guard let nick = parts.first, let channel else {
                addStatus("Usage: /invite <nick> [#channel]", kind: .error); return
            }
            send(IRCMessage(command: "INVITE", parameters: [nick, channel]))

        case "raw", "quote":
            if let message = IRCMessage(parsing: rest) { send(message) }
            else { addStatus("Couldn't parse raw line.", kind: .error) }

        default:
            addStatus("Unknown command: /\(cmd)", kind: .error)
        }
    }

    // MARK: - Ignore

    /// Adds a rule. Returns false if it was already there.
    @discardableResult
    func ignore(_ mask: IgnoreMask) -> Bool {
        guard addRule(mask) else { return false }
        if let nick = mask.plainNick { pushMetadataFlag(CapabilityName.sojuBlocked, nick, true) }
        return true
    }

    /// Removes a rule. Returns false if there was no such rule.
    @discardableResult
    func unignore(_ mask: IgnoreMask) -> Bool {
        // Mirror the stored rule (`Pepe`), not how it was typed (`pepe`).
        guard let removed = removeRule(mask) else { return false }
        if let nick = removed.plainNick { pushMetadataFlag(CapabilityName.sojuBlocked, nick, false) }
        return true
    }

    @discardableResult
    private func addRule(_ mask: IgnoreMask) -> Bool {
        guard ignoreIndex(of: mask) == nil else { return false }
        ignores.append(mask)
        ignoresChanged()
        return true
    }

    /// Removes the rule equal to `mask` (case-insensitively) and returns it.
    @discardableResult
    private func removeRule(_ mask: IgnoreMask) -> IgnoreMask? {
        guard let index = ignoreIndex(of: mask) else { return nil }
        let removed = ignores.remove(at: index)
        ignoresChanged()
        return removed
    }

    // MARK: Mute & pin

    func isMuted(_ name: String) -> Bool { mutedTargets.contains(name.lowercased()) }
    func isPinned(_ name: String) -> Bool { pinnedTargets.contains(name.lowercased()) }

    func setMuted(_ muted: Bool, for name: String) {
        setLocalFlag(CapabilityName.sojuMuted, name, muted)
        pushMetadataFlag(CapabilityName.sojuMuted, name, muted)
    }

    func setPinned(_ pinned: Bool, for name: String) {
        setLocalFlag(CapabilityName.sojuPinned, name, pinned)
        pushMetadataFlag(CapabilityName.sojuPinned, name, pinned)
    }

    // MARK: soju metadata sync (blocked / muted / pinned)

    /// Ignores compare under the network's casemapping; mutes and pins are
    /// stored lowercased (the notification layer has no casemapping).
    private func normalized(_ target: String, for key: String) -> String {
        key == CapabilityName.sojuBlocked ? isupport.caseMapping.fold(target) : target.lowercased()
    }

    /// Only nicks map to ignores; a blocked channel has no equivalent here.
    private func accepts(_ target: String, for key: String) -> Bool {
        target != "*" && (key != CapabilityName.sojuBlocked || !isupport.isChannel(target))
    }

    /// The local state for a key: normalized target → name to send.
    private func localFlags(_ key: String) -> [String: String] {
        switch key {
        case CapabilityName.sojuBlocked:
            var out: [String: String] = [:]
            for rule in ignores { if let nick = rule.plainNick { out[isupport.caseMapping.fold(nick)] = nick } }
            return out
        case CapabilityName.sojuMuted:
            return Dictionary(uniqueKeysWithValues: mutedTargets.map { ($0, $0) })
        default:
            return Dictionary(uniqueKeysWithValues: pinnedTargets.map { ($0, $0) })
        }
    }

    /// Changes local state only (no METADATA sent).
    private func setLocalFlag(_ key: String, _ target: String, _ on: Bool) {
        switch key {
        case CapabilityName.sojuBlocked:
            if on {
                if plainIgnore(for: target) == nil, let mask = IgnoreMask(parsing: target) { addRule(mask) }
            } else if let rule = plainIgnore(for: target) {
                removeRule(rule)
            }
        case CapabilityName.sojuMuted:
            if on { mutedTargets.insert(target.lowercased()) } else { mutedTargets.remove(target.lowercased()) }
            TargetFlagStore.save(mutedTargets, .muted, config.id)
        default:
            if on { pinnedTargets.insert(target.lowercased()) } else { pinnedTargets.remove(target.lowercased()) }
            TargetFlagStore.save(pinnedTargets, .pinned, config.id)
        }
    }

    private func saveSynced(_ key: String) {
        let names = metadataSynced[key] ?? []
        switch key {
        case CapabilityName.sojuBlocked: IgnoreStore.saveSynced(names, for: config.id)
        case CapabilityName.sojuMuted: TargetFlagStore.saveSynced(names, .muted, config.id)
        default: TargetFlagStore.saveSynced(names, .pinned, config.id)
        }
    }

    private func recordSynced(_ key: String, _ target: String, _ on: Bool) {
        let name = normalized(target, for: key)
        if on { metadataSynced[key, default: []].insert(name) } else { metadataSynced[key]?.remove(name) }
        saveSynced(key)
    }

    /// Mirrors a local change to soju. Offline (or before the initial merge)
    /// nothing is sent; the next connect's merge carries the change.
    private func pushMetadataFlag(_ key: String, _ target: String, _ on: Bool) {
        guard metadataActive.contains(key) else { return }
        sendMetadataFlag(key, target, on)
        recordSynced(key, target, on)
    }

    private func sendMetadataFlag(_ key: String, _ target: String, _ on: Bool) {
        send(IRCMessage(command: "METADATA", parameters: [target, "SET", key, on ? "1" : "0"]))
    }

    /// A metadata value: during the initial sync it's soju's state (it reports
    /// every known target, `0` or `1`); afterwards a live change, possibly from
    /// another client.
    private func handleMetadata(target: String, key: String, value: String?) {
        let key = key.lowercased()
        if Self.userMetadataKeys.contains(key) {
            guard target != "*", !isupport.isChannel(target) else { return }
            let nick = isupport.caseMapping.fold(target)
            if let value, !value.isEmpty {
                userMetadata[nick, default: [:]][key] = value
            } else {
                userMetadata[nick]?[key] = nil       // key cleared
            }
            return
        }
        guard Self.syncedMetadataKeys.contains(key), accepts(target, for: key) else { return }
        let on = value == "1"
        if metadataSyncing.contains(key) {
            if on { metadataServerState[key, default: [:]][normalized(target, for: key)] = target }
        } else if metadataActive.contains(key) {
            setLocalFlag(key, target, on)
            recordSynced(key, target, on)
        }
    }

    /// Three-way merge of soju's state for `key`, the local state and the state
    /// at the last sync, so neither side's changes made while apart are lost
    /// or resurrected.
    private func finishMetadataSync(_ key: String) {
        metadataSyncing.remove(key)
        let server = metadataServerState.removeValue(forKey: key) ?? [:]
        let local = localFlags(key)
        let synced = metadataSynced[key] ?? []
        var toServer: [(String, Bool)] = []
        for (name, target) in server where local[name] == nil {
            if synced.contains(name) {
                toServer.append((target, false))        // cleared here while away
            } else {
                setLocalFlag(key, target, true)         // set from another client
            }
        }
        for (name, target) in local where server[name] == nil {
            if synced.contains(name) {
                setLocalFlag(key, target, false)        // cleared elsewhere
            } else {
                toServer.append((target, true))         // set here while away
            }
        }
        metadataActive.insert(key)
        for (target, on) in toServer { sendMetadataFlag(key, target, on) }
        metadataSynced[key] = Set(localFlags(key).keys)
        saveSynced(key)
    }

    /// The rule equal to `mask` under the network's casemapping, since IRC
    /// nicks and hosts are case-insensitive (`/unignore pepe` removes `Pepe`).
    private func ignoreIndex(of mask: IgnoreMask) -> Int? {
        let folded = isupport.caseMapping.fold(mask.pattern)
        return ignores.firstIndex { isupport.caseMapping.fold($0.pattern) == folded }
    }

    func isIgnored(nick: String, user: String?, host: String?, account: String?) -> Bool {
        !ignores.isEmpty && ignores.contains {
            $0.matches(nick: nick, user: user, host: host, account: account,
                       caseMapping: isupport.caseMapping)
        }
    }

    /// Whether a stored line comes from an ignored sender (presence events by
    /// the nick they concern). Our own lines never are.
    func isIgnored(_ line: ChatLine) -> Bool {
        guard !ignores.isEmpty, !line.isSelf, let nick = line.sender ?? line.presenceNick else { return false }
        return isIgnored(nick: nick, user: line.sourceUser, host: line.sourceHost, account: line.account)
    }

    /// The exact-nick rule for `nick`, if one exists — what "Unignore" removes.
    func plainIgnore(for nick: String) -> IgnoreMask? {
        ignores.first { $0.plainNick.map { isupport.equalIdentifiers($0, nick) } ?? false }
    }

    private func ignoresChanged() {
        IgnoreStore.save(ignores, for: config.id)
        for buffer in buffers {
            buffer.typing = buffer.typing.filter { !isIgnored(nick: $0.key, user: nil, host: nil, account: nil) }
            buffer.recomputeUnread()
        }
    }

    /// Feedback for a command, shown where it was typed.
    private func note(_ text: String, in buffer: Buffer) {
        buffer.append(ChatLine(timestamp: Date(), sender: nil, text: text, kind: .event), markUnread: false)
    }

    func join(_ channel: String) {
        sendLabeled(.join(channel), describedAs: "JOIN \(channel)")
    }

    func part(_ buffer: Buffer) {
        if buffer.kind == .channel {
            send(.part(buffer.name))
        }
        removeBuffer(buffer)
    }

    /// Opens (or focuses) a private query buffer for `nick`.
    @discardableResult
    func openQuery(_ nick: String) -> Buffer {
        buffer(named: nick, kind: .query, createIfMissing: true)!
    }

    /// Fetches the member roster for a channel the first time it's viewed. Under
    /// `no-implicit-names` NAMES isn't pushed on JOIN, so we ask on demand
    /// — this is what turns the cap into a real bandwidth win on reconnect (no
    /// roster for channels you never open). A no-op once the list is loaded.
    func loadMembersIfNeeded(_ buffer: Buffer) {
        guard buffer.kind == .channel, buffer.isJoined, !buffer.membersLoaded,
              status == .connected else { return }
        buffer.membersLoaded = true            // optimistic: avoid duplicate NAMES
        send(.names(buffer.name))
        // A single WHO alongside NAMES enriches the roster in one shot: the flags
        // field yields initial away state (H/G) and channel-wide bot mode (+B)
        // without a WHOIS per nick. Prefer WHOX (richer, carries the account) when
        // the server advertises it; fall back to plain WHO otherwise.
        if isupport.tokens["WHOX"] != nil {
            send(IRCMessage(command: "WHO", parameters: [buffer.name, "%tcuhnfar,\(Self.whoxToken)"]))
        } else {
            send(IRCMessage(command: "WHO", parameters: [buffer.name]))
        }
    }

    private func echoIfNeeded(_ text: String, to buffer: Buffer, kind: ChatLine.Kind,
                              replyTo: String? = nil) {
        guard !enabledCaps.contains(CapabilityName.echoMessage) else { return }
        buffer.append(ChatLine(timestamp: Date(), sender: currentNick, text: text,
                               kind: kind, isSelf: true, replyTo: replyTo), markUnread: false)
    }

    // MARK: - Typing notifications (+typing) & reactions (+draft/react)

    /// Called as the user edits the compose field. Emits a throttled
    /// `+typing=active` while there's text, or `+typing=done` once it's cleared.
    func notifyTyping(in buffer: Buffer, hasText: Bool) {
        guard enabledCaps.contains(CapabilityName.messageTags), buffer.kind != .status else { return }
        let key = isupport.caseMapping.fold(buffer.name)
        if hasText {
            let now = Date()
            if let last = typingState[key], now.timeIntervalSince(last) < 3 { return }
            typingState[key] = now
            send(.tagmsg(buffer.name, tags: ["+typing": "active"]))
        } else {
            stopTyping(buffer)
        }
    }

    /// Clears our typing state and tells others we're done (on send or clear).
    private func stopTyping(_ buffer: Buffer) {
        let key = isupport.caseMapping.fold(buffer.name)
        guard typingState[key] != nil else { return }
        typingState[key] = nil
        guard enabledCaps.contains(CapabilityName.messageTags) else { return }
        send(.tagmsg(buffer.name, tags: ["+typing": "done"]))
    }

    // MARK: - Message redaction (draft/message-redaction)

    /// Whether this network lets us delete messages.
    var networkAllowsRedaction: Bool { enabledCaps.contains(CapabilityName.messageRedaction) }

    /// Deletes one of our messages: `REDACT <target> <msgid> [reason]`.
    func redact(_ line: ChatLine, in buffer: Buffer, reason: String? = nil) {
        guard let msgid = line.msgid, networkAllowsRedaction else { return }
        var params = [buffer.name, msgid]
        if let reason, !reason.isEmpty { params.append(reason) }
        send(IRCMessage(command: "REDACT", parameters: params))
        // Apply locally now; a server echo would be idempotent.
        buffer.redact(msgid: msgid, by: currentNick, reason: reason)
    }

    /// Inbound `:source REDACT <target> <msgid> [:reason]` — someone deleted a
    /// message (their own, or as a moderator).
    private func handleRedact(_ message: IRCMessage) {
        guard let target = message.first, let msgid = message.parameter(1) else { return }
        let reason = message.parameters.count > 2 ? message.trailing : nil
        let by = message.source?.nick
        let isSelf = isupport.equalIdentifiers(by ?? "", currentNick)
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : (by ?? target))
        let kind: Buffer.Kind = isupport.isChannel(target) ? .channel : .query
        buffer(named: bufferName, kind: kind, createIfMissing: false)?
            .redact(msgid: msgid, by: by, reason: reason)
    }

    /// Toggles our `emoji` reaction on `line`: adds it via `+draft/react`, or
    /// removes it via `+draft/unreact` if we'd already reacted. The target msgid
    /// rides on both `+reply` (ratified, per the react spec) and the legacy
    /// `+draft/reply`, so clients keying on either name correlate the reaction.
    func toggleReaction(_ emoji: String, to line: ChatLine, in buffer: Buffer) {
        guard let msgid = line.msgid, enabledCaps.contains(CapabilityName.messageTags) else { return }
        let mine = buffer.hasReaction(emoji, onMsgID: msgid, from: currentNick)
        let tag = mine ? "+draft/unreact" : "+draft/react"
        send(.tagmsg(buffer.name, tags: ["+reply": msgid, "+draft/reply": msgid, tag: emoji]))
        // Apply locally right away — instant feedback, and not every server echoes
        // TAGMSG back even with echo-message. Reactions are keyed (emoji, nick) so
        // a later echo or history replay of the same toggle is a no-op.
        if mine { buffer.removeReaction(emoji, fromMsgID: msgid, by: currentNick) }
        else { buffer.addReaction(emoji, toMsgID: msgid, from: currentNick) }
    }

    // MARK: - Inbound dispatch

    private func handle(_ message: IRCMessage) {
        // Registration is fed every message until it completes.
        if !negotiator.isFinished {
            let responses = negotiator.handle(message)
            for response in responses { send(response) }
            if negotiator.isFinished { captureNegotiationResult() }
        }

        // Only the messages of an AROUND reply matter; its replayed events
        // (joins, reactions, …) must not touch the live buffer.
        if let ref = message.tags["batch"], openBatches[ref]?.isAroundContext == true,
           !["PRIVMSG", "NOTICE", "BATCH"].contains(message.command) {
            return
        }

        // A history page's size counts every event it replays (joins, parts,
        // TAGMSGs… under event-playback), not just PRIVMSGs: a busy channel's
        // 100-event page holds only a few messages, and counting those alone
        // made a full page look short — wrongly ending history on servers
        // without `draft/chathistory-end` (soju). PRIVMSG/NOTICE count
        // themselves (multiline parts once, on batch close).
        if let ref = message.tags["batch"], openBatches[ref]?.isHistory == true,
           !["PRIVMSG", "NOTICE", "BATCH"].contains(message.command) {
            openBatches[ref]?.messageCount += 1
        }

        switch message.command {
        case "PING":
            send(.pong(message.trailing ?? ""))
        case "PRIVMSG":
            handlePrivmsg(message, isNotice: false)
        case "NOTICE":
            handlePrivmsg(message, isNotice: true)
        case "JOIN":
            handleJoin(message)
        case "PART":
            handlePart(message)
        case "QUIT":
            handleQuit(message)
        case "NICK":
            handleNick(message)
        case "AWAY":
            handleAway(message)
        case "CAP":
            handleCapChange(message)
        case "SETNAME":
            handleSetname(message)
        case "TOPIC":
            handleTopic(message)
        case "MODE":
            handleMode(message)
        case "BATCH":
            handleBatch(message)
        case "BOUNCER":
            handleBouncer(message)
        case "WEBPUSH":
            if message.first?.uppercased() == "REGISTER" {
                addStatus("Push notifications enabled for this network.", kind: .event)
            }
        case "MARKREAD":
            handleMarkRead(message)
        case "TAGMSG":
            handleTagMsg(message)
        case "INVITE":
            handleInvite(message)
        case "METADATA":
            // METADATA <target> <key> <visibility> [<value>]
            if let target = message.first, let key = message.parameter(1) {
                handleMetadata(target: target, key: key, value: message.parameter(3))
            }
        case "REDACT":
            handleRedact(message)
        case "FAIL", "WARN", "NOTE":
            handleStandardReply(message)
        case "ACK":
            // labeled-response: an empty reply confirming the command completed.
            if let label = message.tags["label"] { pendingLabels[label] = nil }
        case "ERROR":
            addStatus("ERROR: \(message.trailing ?? "")", kind: .error)
        default:
            if let numeric = message.numeric { handleNumeric(numeric, message) }
        }
    }

    private func captureNegotiationResult() {
        guard !didCaptureCaps else { return }
        didCaptureCaps = true
        enabledCaps = negotiator.enabled
        if case let .failed(reason) = negotiator.saslResult {
            saslMessage = reason
            addStatus("⚠️ SASL failed: \(reason)", kind: .error)
        } else if case .succeeded = negotiator.saslResult {
            isAuthenticated = true
            let mechanism = negotiator.activeMechanism?.name ?? config.saslMode.rawValue.uppercased()
            addStatus("Authenticated via SASL (\(mechanism)).", kind: .event)
        }
        // Only the account/control session enumerates networks; a session already
        // bound to one network must not (it would recurse).
        if enabledCaps.contains(CapabilityName.bouncerNetworks), config.boundNetworkID == nil {
            send(IRCMessage(command: "BOUNCER", parameters: ["LISTNETWORKS"]))
        }
        if supportsWebPush { onWebPushReady?() }
    }

    /// cap-notify runtime changes. Once registration finishes the negotiator is a
    /// spent state machine — routing a later ACK through it would emit a stray
    /// `CAP END` (invalid post-registration) or restart SASL — so `CAP NEW/DEL/
    /// ACK/NAK` arriving mid-connection are handled here, keeping `enabledCaps` in
    /// sync as caps appear or disappear (e.g. when a soju network attaches).
    private func handleCapChange(_ message: IRCMessage) {
        // During registration, handle() already feeds every message (CAP included)
        // to the negotiator; only act once it's done to avoid a double request.
        guard negotiator.isFinished, message.parameters.count >= 2 else { return }
        switch message.parameters[1].uppercased() {
        case "NEW":
            // Request newly-offered caps we want and don't already hold. SASL is
            // excluded: we never re-authenticate on a live connection.
            let wanted = capabilityNames(in: message.parameter(2)).filter {
                $0 != CapabilityName.sasl && config.desiredCaps.contains($0)
                    && !enabledCaps.contains($0)
            }
            if !wanted.isEmpty { send(.capReq(wanted.sorted())) }
        case "ACK":
            for name in capabilityNames(in: message.parameter(2)) { enabledCaps.insert(name) }
        case "DEL":
            for name in capabilityNames(in: message.parameter(2)) { enabledCaps.remove(name) }
        default:
            break   // NAK: the server refused; nothing was enabled
        }
    }

    /// Splits a `CAP` capability-list parameter into bare names, dropping any
    /// `=value` suffix (e.g. `sasl=PLAIN` → `sasl`).
    private func capabilityNames(in list: String?) -> [String] {
        (list ?? "").split(separator: " ").map { String($0.split(separator: "=").first ?? $0) }
    }

    /// Registers a Web Push subscription with the bouncer (soju.im/webpush): the
    /// bouncer will POST encrypted highlight/DM notifications to `endpoint`.
    func registerWebPush(endpoint: String, p256dh: String, auth: String) {
        guard supportsWebPush else { return }
        send(IRCMessage(command: "WEBPUSH",
                        parameters: ["REGISTER", endpoint, "p256dh=\(p256dh);auth=\(auth)"]))
    }

    /// Cancels a previously registered Web Push subscription.
    func unregisterWebPush(endpoint: String) {
        guard supportsWebPush else { return }
        send(IRCMessage(command: "WEBPUSH", parameters: ["UNREGISTER", endpoint]))
    }

    private func handleNumeric(_ numeric: IRCNumeric, _ message: IRCMessage) {
        switch numeric {
        case .welcome:
            status = .connected
            if let nick = message.first { currentNick = nick }
            addStatus(message.trailing ?? "Connected.", kind: .event)
            autoJoin()
            // One subscription: soju's per-target flags on a bound soju
            // connection; profile keys elsewhere (soju rejects any other key).
            var subscriptions: [String] = []
            if canSyncMetadata {
                metadataSyncing = Set(Self.syncedMetadataKeys)
                subscriptions += Self.syncedMetadataKeys
            }
            if enabledCaps.contains(CapabilityName.metadata), !isSoju {
                subscriptions += Self.userMetadataKeys
            }
            if !subscriptions.isEmpty {
                send(IRCMessage(command: "METADATA", parameters: ["*", "SUB"] + subscriptions))
            }
            // Channels catch up when the server (re-)JOINs us; queries get no
            // JOIN, so catch up the ones we already hold scrollback for here.
            for buffer in buffers where buffer.kind == .query && buffer.loadedHistory {
                requestHistory(for: buffer)
            }
        case .iSupport:
            isupport.apply(message)
            warnIfClientTagsDenied()
        case .topic:
            if let channel = message.parameter(1),
               let buffer = buffer(named: channel, kind: .channel, createIfMissing: true) {
                buffer.topic = message.trailing
            }
        case .namReply:
            handleNamesReply(message)
        case .whoReply:
            handleWhoReply(message)
        case .whoSpcRpl:
            handleWhoxReply(message)
        case .loggedIn:
            // RPL_LOGGEDIN after registration (e.g. NickServ IDENTIFY): now a
            // push subscription is accepted.
            let wasAuthenticated = isAuthenticated
            isAuthenticated = true
            addStatus(message.parameters.dropFirst().joined(separator: " "), kind: .event)
            if !wasAuthenticated, status == .connected, supportsWebPush { onWebPushReady?() }
        case .keyValue:
            // RPL_KEYVALUE <client> <target> <key> <visibility> [<value>] — the
            // answer to our own SET; same shape as a METADATA update after it.
            if message.parameters.count >= 4 {
                handleMetadata(target: message.parameters[1], key: message.parameters[2],
                               value: message.parameters.count > 4 ? message.parameters[4] : nil)
            }
        case .metadataSubOK:
            // RPL_METADATASUBOK <client> <key>… — soju sends one per key, after
            // that key's current state.
            for key in message.parameters.dropFirst().map({ $0.lowercased() })
                where metadataSyncing.contains(key) {
                finishMetadataSync(key)
            }
        case .metadataUnsubOK, .metadataSubs:
            break
        case .metadataSyncLater:
            // RPL_METADATASYNCLATER <client> <target> [<retry-after>] — the server
            // will have it later; ask again then (bounded, so a bad value can't stall).
            if let target = message.parameter(1) {
                let delay = min(max(Int(message.parameter(2) ?? "") ?? 5, 0), 60)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.status == .connected else { return }
                    self.send(IRCMessage(command: "METADATA", parameters: [target, "SYNC"]))
                }
            }
        case .inviting:
            // RPL_INVITING <me> <nick> <channel> — our /invite went through.
            if let nick = message.parameter(1), let channel = message.parameter(2) {
                let target = buffer(named: channel, kind: .channel, createIfMissing: false) ?? statusBuffer
                note("Invited \(nick) to \(channel).", in: target)
            }
        case .whoisBot:
            // RPL_WHOISBOT <me> <nick> :is a bot — flag them across rosters.
            if let nick = message.parameter(1) {
                for buffer in buffers where buffer.kind == .channel {
                    buffer.setBot(nick, true) { isupport.equalIdentifiers($0, $1) }
                }
            }
        case .endOfNames:
            // Marks the roster complete whether NAMES came implicitly (no cap) or
            // from our lazy request — so we don't re-fetch on the next view.
            if let channel = message.parameter(1) {
                buffer(named: channel, kind: .channel, createIfMissing: false)?.membersLoaded = true
            }
        case .motd, .motdStart, .endOfMotd:
            if let line = message.trailing { addStatus(line, kind: .motd) }
            if numeric == .endOfMotd { startMonitoring() }
        case .noMotd:
            // soju has no MOTD; either way, registration (and ISUPPORT) is done.
            if let line = message.trailing { addStatus(line, kind: .motd) }
            startMonitoring()
        case .monOnline, .monOffline:
            // RPL_MONONLINE <me> :nick!user@host,… / RPL_MONOFFLINE <me> :nick,…
            let online = numeric == .monOnline
            for entry in (message.trailing ?? "").split(separator: ",") {
                let nick = IRCSource(parsing: entry).nick
                guard let query = buffer(named: nick, kind: .query, createIfMissing: false) else { continue }
                query.peerOnline = online
                if !online { query.peerAway = false }
            }
        case .monList, .endOfMonList, .monListFull:
            break
        case .nicknameInUse:
            handleNickInUse()
        default:
            // Surface other numerics in the status window for visibility —
            // as errors, except the 900-range SASL confirmations.
            if numeric.rawValue >= 400 {
                let informational = [.loggedIn, .loggedOut, .saslSuccess].contains(numeric)
                addStatus(message.parameters.dropFirst().joined(separator: " "),
                          kind: informational ? .event : .error)
            }
        }
    }

    // MARK: - Message handlers

    private func handlePrivmsg(_ message: IRCMessage, isNotice: Bool) {
        guard let target = message.first, let text = message.trailing else { return }
        // A part of a draft/multiline message: accumulate, emit on batch close.
        if let ref = message.tags["batch"], openBatches[ref]?.type == CapabilityName.multiline {
            accumulateMultiline(ref, message)
            return
        }
        // A message from the server itself (no user@host, a dotted name) isn't a
        // private conversation: it belongs in the status window.
        if let source = message.source, !source.isUser, !isupport.isChannel(target) {
            if text.hasPrefix("\u{01}") { return }
            statusBuffer.append(ChatLine(timestamp: timestamp(from: message), sender: source.name, text: text,
                                         kind: isNotice ? .notice : .message, msgid: message.tags["msgid"],
                                         isHistorical: batchInfo(for: message)?.isHistory ?? false),
                                markUnread: false)
            return
        }
        let sender = message.source?.nick ?? "*"
        let isSelf = isupport.equalIdentifiers(sender, currentNick)
        let ignored = !isSelf && isIgnored(nick: sender, user: message.source?.user,
                                          host: message.source?.host, account: message.tags["account"])
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : sender)
        let kind: Buffer.Kind = isupport.isChannel(target) ? .channel : .query
        // An ignored sender never opens a new private conversation.
        guard let buffer = buffer(named: bufferName, kind: kind,
                                  createIfMissing: !(ignored && kind == .query)) else { return }

        // Counted before the CTCP filter below: an ignored CTCP still takes a
        // slot in the server's history page.
        let info = batchInfo(for: message)
        if let ref = message.tags["batch"], info?.isHistory == true {
            openBatches[ref]?.messageCount += 1
        }

        var lineKind: ChatLine.Kind = isNotice ? .notice : .message
        var body = text
        if text.hasPrefix("\u{01}ACTION "), text.hasSuffix("\u{01}") {
            body = String(text.dropFirst(8).dropLast())
            lineKind = .action
        } else if text.hasPrefix("\u{01}") {
            return // ignore other CTCP for now
        }
        let line = ChatLine(
            timestamp: timestamp(from: message),
            sender: sender,
            text: body,
            kind: lineKind,
            isSelf: isSelf,
            account: message.tags["account"],
            msgid: message.tags["msgid"],
            replyTo: replyRef(message.tags),
            isHistorical: info?.isHistory ?? false,
            sourceUser: message.source?.user,
            sourceHost: message.source?.host
        )
        if info?.isAroundContext == true {
            aroundContext?.lines.append(line)
            return
        }
        // Ignored lines are kept but hidden by the view: no unread, highlight or
        // notification, so un-ignoring simply shows them again.
        let mentionsMe = !ignored && isHighlight(body)
        buffer.append(line, markUnread: !isSelf && !ignored)
        if mentionsMe && !isSelf && !line.isHistorical { buffer.hasMention = true }
        if !isSelf, !ignored, !isNotice, !line.isHistorical {
            if buffer.kind == .query {
                emitNotification(.directMessage, buffer: buffer, sender: sender, text: body, msgid: line.msgid)
            } else if mentionsMe {
                emitNotification(.mention, buffer: buffer, sender: sender, text: body, msgid: line.msgid)
            }
        }
        // A real message ends any typing indicator from that sender.
        if !line.isHistorical { buffer.typing[sender] = nil }
    }

    private func handleJoin(_ message: IRCMessage) {
        guard let channel = message.first, let source = message.source else { return }
        let buffer = buffer(named: channel, kind: .channel, createIfMissing: true)!
        // A JOIN replayed inside a chathistory batch (event-playback) is an OLD
        // event: it must not mutate live state. Treating a replayed self-JOIN as
        // real re-requested catch-up, whose page contained that same JOIN again —
        // an exponential CHATHISTORY request loop that flooded the connection.
        let historical = batchInfo(for: message)?.isHistory ?? false
        if isupport.equalIdentifiers(source.nick, currentNick) {
            guard !historical else { return }
            buffer.isJoined = true
            // With no-implicit-names the roster arrives only when we ask; a fresh
            // join invalidates whatever we had, so re-fetch on next view.
            buffer.membersLoaded = false
            requestHistory(for: buffer)
        } else {
            // extended-join carries `JOIN <channel> <account> :<realname>`.
            let account = message.parameter(1).flatMap { $0 == "*" ? nil : $0 } ?? message.tags["account"]
            let realname = message.parameters.count >= 3 ? message.trailing : nil
            if !historical {
                addMember(Member(nick: source.nick, prefix: nil, account: account, realname: realname), to: buffer)
            }
            // Carry the msgid so a replayed join dedups instead of stacking up.
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(source.nick) joined", kind: .event,
                                   msgid: message.tags["msgid"],
                                   presence: .join, presenceNick: source.nick,
                                   isHistorical: historical), markUnread: false)
        }
    }

    private func handlePart(_ message: IRCMessage) {
        guard let channel = message.first, let source = message.source,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        // Replayed PARTs (chathistory/event-playback) are old news: they must not
        // flip isJoined or evict current members — only show as scrollback.
        let historical = batchInfo(for: message)?.isHistory ?? false
        if isupport.equalIdentifiers(source.nick, currentNick) {
            if !historical { buffer.isJoined = false }
        } else {
            if !historical { removeMember(source.nick, from: buffer) }
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(source.nick) left", kind: .event,
                                   msgid: message.tags["msgid"],
                                   presence: .part, presenceNick: source.nick,
                                   isHistorical: historical), markUnread: false)
        }
    }

    private func handleQuit(_ message: IRCMessage) {
        guard let source = message.source else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        for buffer in buffers where buffer.kind == .channel {
            if buffer.members.contains(where: { isupport.equalIdentifiers($0.nick, source.nick) }) {
                if !historical { removeMember(source.nick, from: buffer) }
                buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                       text: "\(source.nick) quit", kind: .event,
                                       msgid: message.tags["msgid"],
                                       presence: .quit, presenceNick: source.nick,
                                       isHistorical: historical), markUnread: false)
            }
        }
    }

    private func handleNick(_ message: IRCMessage) {
        guard let source = message.source, let newNick = message.first else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        if !historical, isupport.equalIdentifiers(source.nick, currentNick) { currentNick = newNick }
        // Profile metadata follows the person to their new nick.
        if !historical, let profile = userMetadata.removeValue(forKey: isupport.caseMapping.fold(source.nick)) {
            userMetadata[isupport.caseMapping.fold(newNick)] = profile
        }
        for buffer in buffers where buffer.kind == .channel {
            if let idx = buffer.members.firstIndex(where: { isupport.equalIdentifiers($0.nick, source.nick) }) {
                if !historical { buffer.members[idx].nick = newNick }
                buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                       text: "\(source.nick) is now \(newNick)", kind: .event,
                                       msgid: message.tags["msgid"],
                                       presence: .nick, presenceNick: newNick,
                                       isHistorical: historical), markUnread: false)
            }
        }
    }

    /// away-notify: `:<nick> AWAY :<reason>` marks the user away, a bare
    /// `:<nick> AWAY` marks them back. Reflected as a dimmed roster entry; we
    /// don't add a chat line (away churn is noisier than joins/parts).
    private func handleAway(_ message: IRCMessage) {
        guard let source = message.source else { return }
        let isAway = !message.parameters.isEmpty
        for buffer in buffers where buffer.kind == .channel {
            buffer.setAway(source.nick, isAway) { isupport.equalIdentifiers($0, $1) }
        }
        // away-notify (shared channels) or extended-monitor (monitored nicks).
        buffer(named: source.nick, kind: .query, createIfMissing: false)?.peerAway = isAway
    }

    // MARK: - MONITOR

    /// Watches every open private conversation once registration is done —
    /// MONITOR lists don't survive a reconnect, so this runs per connection.
    private func startMonitoring() {
        guard !monitorStarted, isupport.monitorLimit != nil else { return }
        monitorStarted = true
        monitor(buffers.filter { $0.kind == .query }.map(\.name))
    }

    /// `MONITOR + a,b,…`, within the server's limit and the line length.
    private func monitor(_ nicks: [String]) {
        guard monitorStarted, let limit = isupport.monitorLimit else { return }
        var batch: [String] = []
        var length = 0
        for nick in nicks {
            let key = isupport.caseMapping.fold(nick)
            guard !monitored.contains(key), !isupport.isChannel(nick) else { continue }
            if let limit, monitored.count >= limit { break }
            if length + nick.count + 1 > 400 {
                send(IRCMessage(command: "MONITOR", parameters: ["+", batch.joined(separator: ",")]))
                batch = []
                length = 0
            }
            monitored.insert(key)
            batch.append(nick)
            length += nick.count + 1
        }
        if !batch.isEmpty {
            send(IRCMessage(command: "MONITOR", parameters: ["+", batch.joined(separator: ",")]))
        }
    }

    private func unmonitor(_ nick: String) {
        guard monitorStarted, monitored.remove(isupport.caseMapping.fold(nick)) != nil else { return }
        send(IRCMessage(command: "MONITOR", parameters: ["-", nick]))
    }

    private func handleTopic(_ message: IRCMessage) {
        guard let channel = message.first,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        buffer.topic = message.trailing
        buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                               text: "\(message.source?.nick ?? "?") changed the topic: \(message.trailing ?? "")",
                               kind: .event), markUnread: false)
    }

    private func handleMode(_ message: IRCMessage) {
        guard let target = message.first, isupport.isChannel(target) else { return }
        // A basic record; full mode tracking (bans, etc.) is out of scope here.
        let modeText = message.parameters.dropFirst().joined(separator: " ")
        if let buffer = buffer(named: target, kind: .channel, createIfMissing: false) {
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(message.source?.nick ?? "?") set mode \(modeText)", kind: .event),
                          markUnread: false)
        }
    }

    private func handleNamesReply(_ message: IRCMessage) {
        // <nick> <symbol> <channel> :<names>
        guard let channel = message.parameter(2), let names = message.trailing,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: true) else { return }
        let symbols = isupport.prefixSymbols
        for entry in names.split(separator: " ") {
            var token = Substring(entry)
            var prefix: Character?
            while let first = token.first, symbols.contains(first) {
                if prefix == nil { prefix = first } // keep highest (first listed)
                token = token.dropFirst()
            }
            // userhost-in-names may attach !user@host.
            let nick = String(token.split(separator: "!").first ?? token)
            guard !nick.isEmpty else { continue }
            addMember(Member(nick: nick, prefix: prefix, account: nil), to: buffer, replacePrefix: true)
        }
    }

    /// Plain `WHO` reply (RPL_WHOREPLY): `<me> <channel> <user> <host> <server>
    /// <nick> <flags> :<hops> <realname>`.
    private func handleWhoReply(_ message: IRCMessage) {
        guard let channel = message.parameter(1), let nick = message.parameter(5),
              let flags = message.parameter(6),
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        applyWhoFlags(flags, toNick: nick, in: buffer, account: nil)
    }

    /// WHOX reply (RPL_WHOSPCRPL) for our `%tcuhnfar` query: `<me> <token>
    /// <channel> <user> <host> <nick> <flags> <account> :<realname>`. Same
    /// enrichment as `handleWhoReply` plus the services account (`0` = none).
    private func handleWhoxReply(_ message: IRCMessage) {
        guard message.parameter(1) == Self.whoxToken,
              let channel = message.parameter(2), let nick = message.parameter(5),
              let flags = message.parameter(6),
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        let account = message.parameter(7).flatMap { $0 == "0" ? nil : $0 }
        applyWhoFlags(flags, toNick: nick, in: buffer, account: account)
    }

    /// Interprets a WHO/WHOX flags field — `H` here / `G` gone(away), `B` bot —
    /// and updates the member (adding a bare entry if WHO outran NAMES). Away is
    /// set both ways (away-notify keeps it live after); bot is only ever set, so a
    /// server that omits `B` from WHO can't clear a flag a WHOIS established.
    private func applyWhoFlags(_ flags: String, toNick nick: String, in buffer: Buffer, account: String?) {
        if let account, !account.isEmpty {
            addMember(Member(nick: nick, prefix: nil, account: account), to: buffer)
        } else if !buffer.members.contains(where: { isupport.equalIdentifiers($0.nick, nick) }) {
            addMember(Member(nick: nick, prefix: nil, account: nil), to: buffer)
        }
        buffer.setAway(nick, flags.hasPrefix("G")) { isupport.equalIdentifiers($0, $1) }
        if flags.contains("B") { buffer.setBot(nick, true) { isupport.equalIdentifiers($0, $1) } }
    }

    // MARK: - Batches & soju extensions

    private func handleBatch(_ message: IRCMessage) {
        guard let reference = message.first else { return }
        if reference.hasPrefix("+") {
            let ref = String(reference.dropFirst())
            let type = message.parameter(1) ?? ""
            let isHistory = type == "chathistory"
            var info = BatchInfo(type: type, target: message.parameter(2), isHistory: isHistory)
            if isHistory, let target = info.target,
               catchUpTargets.contains(where: { isupport.equalIdentifiers($0, target) }) {
                info.isCatchUp = true
            }
            if isHistory, aroundAwaitingBatch, let target = info.target,
               let context = aroundContext, isupport.equalIdentifiers(context.target, target) {
                info.isAroundContext = true
                aroundAwaitingBatch = false
            }
            if isHistory, !info.isAroundContext, message.tags["draft/chathistory-end"] != nil {
                info.isEndOfHistory = true
                serverSignalsHistoryEnd = true
            }
            if type == CapabilityName.multiline {
                // Whole-message tags (msgid/time/account) and the sender ride on
                // the opening BATCH; remember the enclosing batch for history.
                info.parentRef = message.tags["batch"]
                info.multilineSource = message.source
                info.multilineTags = message.tags
            }
            openBatches[ref] = info
            // labeled-response wraps a command's replies; remember its label.
            if type == "labeled-response", let label = message.tags["label"] {
                labeledBatches[ref] = label
            }
        } else if reference.hasPrefix("-") {
            let ref = String(reference.dropFirst())
            if let label = labeledBatches[ref] {
                pendingLabels[label] = nil
                labeledBatches[ref] = nil
            }
            if let info = openBatches[ref], info.type == CapabilityName.multiline {
                finishMultiline(info)
            }
            if let info = openBatches[ref], info.isAroundContext {
                finishAroundContext(failed: false)
            } else if let info = openBatches[ref], info.isHistory, let target = info.target,
               let buffer = buffer(named: target,
                                   kind: isupport.isChannel(target) ? .channel : .query,
                                   createIfMissing: false) {
                buffer.isLoadingHistory = false
                // A LATEST/BEFORE page ends history when the server says so
                // (`draft/chathistory-end`) or it's empty; servers that never send
                // the tag fall back to "short page = start of history". A catch-up
                // (AFTER) page just means we're up to date, so keep the "load
                // older" affordance alive.
                if !info.isCatchUp {
                    let reachedStart = info.isEndOfHistory || info.messageCount == 0
                        || (!serverSignalsHistoryEnd && info.messageCount < Self.historyPageSize)
                    if reachedStart { buffer.historyExhausted = true }
                    advanceOriginalSeek(in: buffer)
                }
                if info.isCatchUp {
                    catchUpTargets = catchUpTargets.filter { !isupport.equalIdentifiers($0, target) }
                    continueCatchUp(buffer, fullPage: info.messageCount >= Self.historyPageSize
                                                       && !info.isEndOfHistory)
                }
                buffer.recomputeUnread()
            }
            openBatches[ref] = nil
        }
    }

    private func batchInfo(for message: IRCMessage) -> BatchInfo? {
        guard let ref = message.tags["batch"] else { return nil }
        return openBatches[ref]
    }

    // MARK: - draft/multiline

    /// Appends one part of an open multiline batch. Parts are joined by newline
    /// unless tagged `draft/multiline-concat` (then glued to the previous part).
    private func accumulateMultiline(_ ref: String, _ message: IRCMessage) {
        guard var info = openBatches[ref] else { return }
        let body = message.trailing ?? ""
        if !info.multilineHasContent {
            info.multilineText = body
            info.multilineHasContent = true
        } else if message.tags["draft/multiline-concat"] != nil {
            info.multilineText += body
        } else {
            info.multilineText += "\n" + body
        }
        openBatches[ref] = info
    }

    /// Emits the accumulated multiline message as a single `ChatLine`.
    private func finishMultiline(_ info: BatchInfo) {
        guard let target = info.target, let source = info.multilineSource else { return }
        let sender = source.nick
        let isSelf = isupport.equalIdentifiers(sender, currentNick)
        let ignored = !isSelf && isIgnored(nick: sender, user: source.user, host: source.host,
                                          account: info.multilineTags["account"])
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : sender)
        let kind: Buffer.Kind = isupport.isChannel(target) ? .channel : .query
        guard let buffer = buffer(named: bufferName, kind: kind,
                                  createIfMissing: !(ignored && kind == .query)) else { return }

        // The batch may itself sit inside a chathistory batch; if so it counts
        // as one history message and the line is historical.
        let historical = info.parentRef.flatMap { openBatches[$0]?.isHistory } ?? false
        if historical, let parent = info.parentRef { openBatches[parent]?.messageCount += 1 }

        var text = info.multilineText
        var lineKind: ChatLine.Kind = .message
        if text.hasPrefix("\u{01}ACTION "), text.hasSuffix("\u{01}") {
            text = String(text.dropFirst(8).dropLast())
            lineKind = .action
        }
        let ts: Date
        if let raw = info.multilineTags["time"], let date = Self.timeFormatter.date(from: raw) {
            ts = date
        } else {
            ts = Date()
        }
        let line = ChatLine(
            timestamp: ts, sender: sender, text: text, kind: lineKind, isSelf: isSelf,
            account: info.multilineTags["account"], msgid: info.multilineTags["msgid"],
            replyTo: replyRef(info.multilineTags), isHistorical: historical,
            sourceUser: source.user, sourceHost: source.host)
        if info.parentRef.flatMap({ openBatches[$0]?.isAroundContext }) == true {
            aroundContext?.lines.append(line)
            return
        }
        let mentionsMe = !ignored && isHighlight(text)
        buffer.append(line, markUnread: !isSelf && !ignored)
        if mentionsMe && !isSelf && !historical { buffer.hasMention = true }
        if !isSelf, !ignored, !historical {
            if buffer.kind == .query {
                emitNotification(.directMessage, buffer: buffer, sender: sender, text: text, msgid: line.msgid)
            } else if mentionsMe {
                emitNotification(.mention, buffer: buffer, sender: sender, text: text, msgid: line.msgid)
            }
        }
        if !historical { buffer.typing[sender] = nil }
    }

    // MARK: - setname

    /// Inbound `:nick SETNAME :<realname>` — a user changed their realname.
    private func handleSetname(_ message: IRCMessage) {
        guard let source = message.source, let newName = message.trailing else { return }
        for buffer in buffers where buffer.kind == .channel {
            guard let i = buffer.members.firstIndex(where: {
                isupport.equalIdentifiers($0.nick, source.nick)
            }) else { continue }
            buffer.members[i].realname = newName
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(source.nick) changed realname to \"\(newName)\"", kind: .event),
                          markUnread: false)
        }
        if isupport.equalIdentifiers(source.nick, currentNick) {
            addStatus("Your realname is now \"\(newName)\".", kind: .event)
        }
    }

    /// Parses `BOUNCER NETWORK <id> <attr=val;...>` (soju.im/bouncer-networks).
    private func handleBouncer(_ message: IRCMessage) {
        guard message.parameter(0)?.uppercased() == "NETWORK",
              let netID = message.parameter(1) else { return }
        let attrsRaw = message.parameter(2) ?? "*"
        if attrsRaw == "*" {
            bouncerNetworks.removeAll { $0.id == netID }
            return
        }
        var attributes: [String: String] = [:]
        for pair in attrsRaw.split(separator: ";") {
            if let eq = pair.firstIndex(of: "=") {
                attributes[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            }
        }
        let network = BouncerNetwork(
            id: netID,
            name: attributes["name"] ?? netID,
            state: attributes["state"],
            host: attributes["host"],
            nickname: attributes["nickname"],
            attributes: attributes
        )
        if let index = bouncerNetworks.firstIndex(where: { $0.id == netID }) {
            bouncerNetworks[index] = network
        } else {
            bouncerNetworks.append(network)
        }
    }

    private func requestHistory(for buffer: Buffer) {
        guard enabledCaps.contains(CapabilityName.chathistory) else { return }
        // One request at a time per buffer: overlapping catch-ups compounded into
        // a request flood when something re-triggered this mid-flight.
        guard !buffer.isLoadingHistory else { return }
        guard buffer.loadedHistory, let newest = buffer.newestMessageTimestamp else {
            // First view of this channel (or nothing to catch up from): pull the
            // most recent page.
            buffer.loadedHistory = true
            buffer.isLoadingHistory = true
            send(IRCMessage(command: "CHATHISTORY",
                            parameters: ["LATEST", buffer.name, "*", "\(Self.historyPageSize)"]))
            return
        }
        // Reconnect (soju re-JOINs us) or restored scrollback: pull everything
        // since our newest line. soju doesn't auto-replay backlog to
        // chathistory-capable clients. Overlap is dropped in `Buffer.append` (by
        // msgid, or by content where the server sends none).
        buffer.isLoadingHistory = true
        catchUpTargets.insert(buffer.name)
        let selector = "timestamp=\(Self.timeFormatter.string(from: newest))"
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["AFTER", buffer.name, selector, "\(Self.historyPageSize)"]))
    }

    /// After a catch-up page: keep paging forward while pages come back full,
    /// up to `maxCatchUpPages`. Past that the gap is too big to bridge, so drop
    /// the local scrollback and start over from the latest page.
    private func continueCatchUp(_ buffer: Buffer, fullPage: Bool) {
        let key = isupport.caseMapping.fold(buffer.name)
        guard fullPage else {
            catchUpPages[key] = nil
            return
        }
        let pages = (catchUpPages[key] ?? 1) + 1
        if pages > Self.maxCatchUpPages {
            catchUpPages[key] = nil
            buffer.resetHistory()
        } else {
            catchUpPages[key] = pages
        }
        requestHistory(for: buffer)
    }

    // MARK: - Reply context (CHATHISTORY AROUND)

    /// Shows the original of a reply that's older than the loaded scrollback:
    /// `CHATHISTORY AROUND` into a sheet where the server takes msgid references,
    /// otherwise (soju) page back through the timeline until it appears.
    func showOriginal(of msgid: String, in buffer: Buffer) {
        if acceptsMsgidReferences {
            loadContext(around: msgid, in: buffer)
            return
        }
        guard enabledCaps.contains(CapabilityName.chathistory), status == .connected,
              !buffer.historyExhausted else {
            aroundContext = AroundContext(target: buffer.name, msgid: msgid, isLoading: false, failed: true)
            return
        }
        originalSeek = (isupport.caseMapping.fold(buffer.name), buffer.name, msgid, Self.maxSeekPages - 1)
        // If a page is already in flight, its arrival advances the seek.
        loadMoreHistory(for: buffer)
    }

    func consumeJump() { jumpRequest = nil }

    /// After an older page lands: jump if the original showed up, else keep
    /// paging back while pages and budget remain.
    private func advanceOriginalSeek(in buffer: Buffer) {
        guard var seek = originalSeek, seek.bufferKey == isupport.caseMapping.fold(buffer.name) else { return }
        if let line = buffer.lines.first(where: { $0.msgid == seek.msgid }) {
            originalSeek = nil
            jumpRequest = JumpRequest(bufferID: buffer.id, lineID: line.id)
        } else if seek.pagesLeft > 0, !buffer.historyExhausted {
            seek.pagesLeft -= 1
            originalSeek = seek
            loadMoreHistory(for: buffer)
        } else {
            originalSeek = nil
            failOriginal(seek.msgid, in: buffer.name)
        }
    }

    private func failOriginal(_ msgid: String, in target: String) {
        aroundContext = AroundContext(target: target, msgid: msgid, isLoading: false, failed: true)
    }

    /// Fetches the messages around `msgid` — the original of a reply that's
    /// older than the loaded scrollback — into `aroundContext`.
    func loadContext(around msgid: String, in buffer: Buffer) {
        guard enabledCaps.contains(CapabilityName.chathistory), status == .connected else {
            aroundContext = AroundContext(target: buffer.name, msgid: msgid, isLoading: false, failed: true)
            return
        }
        // Serialized with the buffer's other history requests: chathistory
        // batches carry only the target, so two in flight couldn't be told apart.
        guard !buffer.isLoadingHistory else { return }
        buffer.isLoadingHistory = true
        aroundContext = AroundContext(target: buffer.name, msgid: msgid)
        aroundAwaitingBatch = true
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["AROUND", buffer.name, "msgid=\(msgid)", "\(Self.aroundContextSize)"]))
        // A server without AROUND may answer with a bare numeric instead of FAIL;
        // don't leave the buffer's history requests blocked forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.aroundAwaitingBatch, self.aroundContext?.msgid == msgid else { return }
            self.finishAroundContext(failed: true)
        }
    }

    func dismissAroundContext() {
        if aroundContext?.isLoading == true {
            aroundContext?.dismissed = true
        } else {
            aroundContext = nil
        }
    }

    private static let aroundContextSize = 30

    private func finishAroundContext(failed: Bool) {
        guard var context = aroundContext else { return }
        aroundAwaitingBatch = false
        context.lines.sort { $0.timestamp < $1.timestamp }
        context.isLoading = false
        context.failed = failed || !context.lines.contains { $0.msgid == context.msgid }
        aroundContext = context.dismissed ? nil : context
        buffer(named: context.target, kind: isupport.isChannel(context.target) ? .channel : .query,
               createIfMissing: false)?.isLoadingHistory = false
    }

    // MARK: - On-device history

    /// The channels and queries to keep on disk, newest lines only.
    func historySnapshot() -> HistoryStore.Snapshot {
        let kept = buffers.filter { $0.kind != .status && !$0.lines.isEmpty }.map {
            HistoryStore.BufferSnapshot(name: $0.name, kind: $0.kind, topic: $0.topic,
                                        readMarker: $0.readMarker,
                                        historyExhausted: $0.historyExhausted
                                            && $0.lines.count <= HistoryStore.maxLinesPerBuffer,
                                        lines: Array($0.lines.suffix(HistoryStore.maxLinesPerBuffer)))
        }
        return HistoryStore.Snapshot(buffers: kept)
    }

    /// Recreates buffers from a saved snapshot. Call before connecting; the
    /// server's JOINs then mark the channels joined and trigger the catch-up.
    func restoreHistory(_ snapshot: HistoryStore.Snapshot) {
        // Nicks can't contain dots: a "query" named like a server was a server
        // notice mistaken for a private message by older versions.
        for saved in snapshot.buffers where saved.kind != .status
            && !(saved.kind == .query && saved.name.contains(".")) {
            guard let buffer = buffer(named: saved.name, kind: saved.kind, createIfMissing: true),
                  buffer.lines.isEmpty else { continue }
            buffer.restore(saved)
        }
    }

    /// Pulls an older page of scrollback (draft/chathistory `BEFORE`). Triggered
    /// when the user scrolls to the top of a conversation.
    func loadMoreHistory(for buffer: Buffer) {
        guard enabledCaps.contains(CapabilityName.chathistory),
              buffer.kind == .channel || buffer.kind == .query,
              !buffer.isLoadingHistory, !buffer.historyExhausted,
              let oldest = buffer.lines.first else { return }
        buffer.isLoadingHistory = true
        // Prefer the stable msgid where the server takes it (MSGREFTYPES);
        // otherwise a timestamp selector.
        let selector = oldest.msgid.flatMap { acceptsMsgidReferences ? "msgid=\($0)" : nil }
            ?? "timestamp=\(Self.timeFormatter.string(from: oldest.timestamp))"
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["BEFORE", buffer.name, selector, "\(Self.historyPageSize)"]))
    }

    // MARK: - Read markers (draft/read-marker)

    /// Marks `buffer` read up to its latest line, advancing the local marker and
    /// (if the cap is active) telling the bouncer so other devices stay in sync.
    func markRead(_ buffer: Buffer) {
        guard buffer.kind != .status else { return }
        buffer.hasMention = false
        buffer.unreadCount = 0
        guard let newest = buffer.lines.last(where: { $0.kind.countsAsUnread }) else { return }
        if let marker = buffer.readMarker, marker >= newest.timestamp { return }
        buffer.readMarker = newest.timestamp
        guard enabledCaps.contains(CapabilityName.readMarker) else { return }
        let stamp = Self.timeFormatter.string(from: newest.timestamp)
        send(IRCMessage(command: "MARKREAD", parameters: [buffer.name, "timestamp=\(stamp)"]))
    }

    /// Inbound `MARKREAD <target> timestamp=…` — another device (or this one,
    /// confirmed) moved the read boundary.
    private func handleMarkRead(_ message: IRCMessage) {
        guard let target = message.first,
              let buffer = buffer(named: target,
                                  kind: isupport.isChannel(target) ? .channel : .query,
                                  createIfMissing: false) else { return }
        let arg = message.parameter(1) ?? "*"
        guard arg.hasPrefix("timestamp="),
              let date = Self.timeFormatter.date(from: String(arg.dropFirst("timestamp=".count)))
        else { return }
        if buffer.readMarker == nil || date > buffer.readMarker! {
            buffer.readMarker = date
            buffer.recomputeUnread()
        }
    }

    // MARK: - TAGMSG (typing + reactions)

    /// Inbound `TAGMSG` carrying client-only tags: `+typing` state and/or a
    /// The parent-message reference from a message's tags. Prefers the ratified
    /// `+reply` and falls back to the legacy `+draft/reply`, so we still thread
    /// (and correlate reactions) with clients that haven't dropped the prefix.
    private func replyRef(_ tags: [String: String]) -> String? {
        tags["+reply"] ?? tags["+draft/reply"]
    }

    /// `+draft/react` reaction.
    /// `:inviter INVITE <nick> <channel>` — an invitation for us, or (with
    /// `invite-notify`) a channel operator inviting someone else.
    private func handleInvite(_ message: IRCMessage) {
        guard let invitee = message.first, let channel = message.parameter(1),
              let source = message.source else { return }
        let historical = batchInfo(for: message)?.isHistory ?? false
        if isupport.equalIdentifiers(invitee, currentNick) {
            guard !isIgnored(nick: source.nick, user: source.user, host: source.host,
                             account: message.tags["account"]) else { return }
            let text = "\(source.nick) invited you to \(channel)"
            statusBuffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                         text: "\(text) · /join \(channel)", kind: .event,
                                         msgid: message.tags["msgid"], isHistorical: historical),
                                markUnread: false)
            guard !historical else { return }
            onNotifiableEvent?(NotifiableEvent(
                kind: .invite, sessionID: id, bufferID: statusBuffer.id,
                conversation: channel, bufferName: statusBuffer.name,
                msgid: message.tags["msgid"], sender: source.nick, text: text))
        } else if let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) {
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(source.nick) invited \(invitee)", kind: .event,
                                   msgid: message.tags["msgid"], isHistorical: historical),
                          markUnread: false)
        }
    }

    private func handleTagMsg(_ message: IRCMessage) {
        guard let target = message.first, let source = message.source else { return }
        let sender = source.nick
        let isSelf = isupport.equalIdentifiers(sender, currentNick)
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : sender)
        guard let buffer = buffer(named: bufferName,
                                  kind: isupport.isChannel(target) ? .channel : .query,
                                  createIfMissing: false) else { return }

        // A TAGMSG replayed more than once (overlapping catch-up pages) must not
        // re-apply its state change — a replayed react would resurrect a reaction
        // the user has since removed. Keyed on the TAGMSG's own msgid.
        if let mid = message.tags["msgid"], !buffer.markProcessed(mid) { return }
        // Reactions and typing from ignored senders are dropped outright.
        if !isSelf, isIgnored(nick: sender, user: source.user, host: source.host,
                              account: message.tags["account"]) { return }

        if let emoji = message.tags["+draft/react"], let msgid = replyRef(message.tags) {
            buffer.addReaction(emoji, toMsgID: msgid, from: sender)
        }
        if let emoji = message.tags["+draft/unreact"], let msgid = replyRef(message.tags) {
            buffer.removeReaction(emoji, fromMsgID: msgid, by: sender)
        }
        if let typing = message.tags["+typing"], !isSelf {
            switch typing {
            case "active", "paused": buffer.typing[sender] = Date()
            case "done": buffer.typing[sender] = nil
            default: break
            }
        }
    }

    // MARK: - Standard replies (FAIL / WARN / NOTE) & labeled-response

    /// `<FAIL|WARN|NOTE> <command> <code> [context…] :<description>` — a
    /// machine-readable status from the server, shown legibly in the status
    /// window and tied back to the originating command when labelled.
    private func handleStandardReply(_ message: IRCMessage) {
        let command = message.first ?? "*"
        let code = message.parameter(1) ?? ""
        let description = message.trailing ?? ""

        // Resolve a labeled-response label (direct tag, or via the batch it's in).
        let label = message.tags["label"]
            ?? message.tags["batch"].flatMap { labeledBatches[$0] }
        let attribution = label.flatMap { pendingLabels[$0] }.map { "\($0) → " } ?? ""

        let symbol: String
        let kind: ChatLine.Kind
        switch message.command {
        case "FAIL": symbol = "✗"; kind = .error
        case "WARN": symbol = "⚠️"; kind = .error
        default:     symbol = "ℹ️"; kind = .event   // NOTE
        }
        if message.command == "FAIL", command == "CHATHISTORY" {
            if aroundContext?.isLoading == true { finishAroundContext(failed: true) }
            // FAIL names no target, and requests are one-per-buffer: unblock them
            // all rather than leave a buffer stuck "loading" forever.
            for buffer in buffers { buffer.isLoadingHistory = false }
            catchUpTargets.removeAll()
            if let seek = originalSeek {
                originalSeek = nil
                failOriginal(seek.msgid, in: seek.bufferName)
            }
        }
        let label2 = command == "*" ? code : "\(command) \(code)"
        addStatus("\(symbol) \(attribution)\(label2): \(description)", kind: kind)
    }

    /// Sends a command, attaching a `label` when labeled-response is active so
    /// any reply (FAIL/ACK/batch) can be correlated back to it.
    private func sendLabeled(_ message: IRCMessage, describedAs description: String) {
        guard enabledCaps.contains(CapabilityName.labeledResponse) else {
            send(message)
            return
        }
        labelCounter += 1
        let label = "arkhe\(labelCounter)"
        pendingLabels[label] = description
        var labeled = message
        labeled.tags["label"] = label
        send(labeled)
    }

    // MARK: - Buffer & member bookkeeping

    @discardableResult
    private func buffer(named name: String, kind: Buffer.Kind, createIfMissing: Bool) -> Buffer? {
        let key = isupport.caseMapping.fold(name)
        if let existing = bufferIndex[key] { return existing }
        guard createIfMissing else { return nil }
        let buffer = Buffer(name: name, kind: kind)
        buffer.isHidden = { [weak self] in self?.isIgnored($0) ?? false }
        bufferIndex[key] = buffer
        buffers.append(buffer)
        if kind == .query { monitor([name]) }
        return buffer
    }

    private func removeBuffer(_ buffer: Buffer) {
        guard buffer.kind != .status else { return }
        if buffer.kind == .query { unmonitor(buffer.name) }
        let key = isupport.caseMapping.fold(buffer.name)
        bufferIndex[key] = nil
        buffers.removeAll { $0.id == buffer.id }
    }

    private func addMember(_ member: Member, to buffer: Buffer, replacePrefix: Bool = false) {
        if let index = buffer.members.firstIndex(where: { isupport.equalIdentifiers($0.nick, member.nick) }) {
            if replacePrefix { buffer.members[index].prefix = member.prefix }
            if let account = member.account { buffer.members[index].account = account }
            if let realname = member.realname { buffer.members[index].realname = realname }
        } else {
            buffer.members.append(member)
        }
    }

    private func removeMember(_ nick: String, from buffer: Buffer) {
        buffer.members.removeAll { isupport.equalIdentifiers($0.nick, nick) }
    }

    // MARK: - Helpers

    /// Joins the configured channels and — on a direct connection — the ones
    /// open in the sidebar, so a reconnect (or a launch with restored history)
    /// puts you back where you were. A bouncer rejoins you itself.
    private func autoJoin() {
        var channels = config.autoJoinChannels.filter { !$0.isEmpty }
        if !config.isBouncer {
            for buffer in buffers where buffer.kind == .channel
                && !channels.contains(where: { isupport.equalIdentifiers($0, buffer.name) }) {
                channels.append(buffer.name)
            }
        }
        for channel in channels { join(channel) }
    }

    /// One-time heads-up when the network's `CLIENTTAGDENY` blocks reactions, so
    /// the user understands why teraflops won't see them (it's not a bug).
    private func warnIfClientTagsDenied() {
        guard !didWarnClientTagDeny, !networkAllowsReactions else { return }
        didWarnClientTagDeny = true
        let net = isupport.network ?? "This network"
        addStatus("ℹ️ \(net) doesn't relay reactions between users (CLIENTTAGDENY); you'll only see them on your own devices.",
                  kind: .event)
    }

    private func handleNickInUse() {
        let fallback = currentNick + "_"
        currentNick = fallback
        send(.nick(fallback))
    }

    private func timestamp(from message: IRCMessage) -> Date {
        if let raw = message.tags["time"], let date = Self.timeFormatter.date(from: raw) {
            return date
        }
        return Date()
    }

    func addStatus(_ text: String, kind: ChatLine.Kind) {
        statusBuffer.append(ChatLine(timestamp: Date(), sender: nil, text: text, kind: kind),
                            markUnread: false)
    }

    /// Whether `body` should highlight the user: it names their nick or any of
    /// their configured keywords (case-insensitive).
    private func isHighlight(_ body: String) -> Bool {
        if body.localizedCaseInsensitiveContains(currentNick) { return true }
        return highlightKeywords().contains {
            !$0.isEmpty && body.localizedCaseInsensitiveContains($0)
        }
    }

    /// Hands a highlight or direct message to the app's notification layer. The
    /// title is the channel for a mention and the sender for a direct message.
    private func emitNotification(_ kind: NotifiableEvent.Kind, buffer: Buffer,
                                  sender: String, text: String, msgid: String?) {
        onNotifiableEvent?(NotifiableEvent(
            kind: kind, sessionID: id, bufferID: buffer.id,
            conversation: kind == .mention ? buffer.name : sender,
            bufferName: buffer.name, msgid: msgid, sender: sender, text: text))
    }
}
