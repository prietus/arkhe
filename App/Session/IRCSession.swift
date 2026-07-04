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
    var supportsWebPush: Bool { enabledCaps.contains(CapabilityName.webpush) }

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

    private let connection = IRCConnection()
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

    private struct BatchInfo {
        var type: String
        var target: String?
        var isHistory: Bool
        var messageCount: Int = 0
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

    private static let timeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(config: SessionConfig) {
        self.id = config.id
        self.config = config
        self.currentNick = config.nickname
        self.negotiator = CapabilityNegotiator(desired: config.desiredCaps, mechanism: config.saslMechanism)
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
    /// literal message); otherwise it's a PRIVMSG with optional `+draft/reply`.
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
        if let replyTo { tags["+draft/reply"] = replyTo }

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
        echoIfNeeded(body, to: buffer, kind: .message, replyTo: tags["+draft/reply"])
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

        case "raw", "quote":
            if let message = IRCMessage(parsing: rest) { send(message) }
            else { addStatus("Couldn't parse raw line.", kind: .error) }

        default:
            addStatus("Unknown command: /\(cmd)", kind: .error)
        }
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
    /// `soju.im/no-implicit-names` NAMES isn't pushed on JOIN, so we ask on demand
    /// — this is what turns the cap into a real bandwidth win on reconnect (no
    /// roster for channels you never open). A no-op once the list is loaded.
    func loadMembersIfNeeded(_ buffer: Buffer) {
        guard buffer.kind == .channel, buffer.isJoined, !buffer.membersLoaded,
              status == .connected else { return }
        buffer.membersLoaded = true            // optimistic: avoid duplicate NAMES
        send(.names(buffer.name))
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
    /// removes it via `+draft/unreact` if we'd already reacted (both carry the
    /// target msgid in `+draft/reply`).
    func toggleReaction(_ emoji: String, to line: ChatLine, in buffer: Buffer) {
        guard let msgid = line.msgid, enabledCaps.contains(CapabilityName.messageTags) else { return }
        let mine = buffer.hasReaction(emoji, onMsgID: msgid, from: currentNick)
        let tag = mine ? "+draft/unreact" : "+draft/react"
        send(.tagmsg(buffer.name, tags: ["+draft/reply": msgid, tag: emoji]))
        // Echo locally unless the server will echo the TAGMSG back to us.
        guard !enabledCaps.contains(CapabilityName.echoMessage) else { return }
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
            addStatus("Authenticated via SASL (\(config.saslMode.rawValue.uppercased())).", kind: .event)
        }
        // Only the account/control session enumerates networks; a session already
        // bound to one network must not (it would recurse).
        if enabledCaps.contains(CapabilityName.bouncerNetworks), config.boundNetworkID == nil {
            send(IRCMessage(command: "BOUNCER", parameters: ["LISTNETWORKS"]))
        }
        if enabledCaps.contains(CapabilityName.webpush) { onWebPushReady?() }
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
        case .nicknameInUse:
            handleNickInUse()
        default:
            // Surface other numerics in the status window for visibility.
            if numeric.rawValue >= 400 {
                addStatus(message.parameters.dropFirst().joined(separator: " "), kind: .error)
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
        let sender = message.source?.nick ?? "*"
        let isSelf = isupport.equalIdentifiers(sender, currentNick)
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : sender)
        let kind: Buffer.Kind = isupport.isChannel(target) ? .channel : .query
        guard let buffer = buffer(named: bufferName, kind: kind, createIfMissing: true) else { return }

        var lineKind: ChatLine.Kind = isNotice ? .notice : .message
        var body = text
        if text.hasPrefix("\u{01}ACTION "), text.hasSuffix("\u{01}") {
            body = String(text.dropFirst(8).dropLast())
            lineKind = .action
        } else if text.hasPrefix("\u{01}") {
            return // ignore other CTCP for now
        }

        let info = batchInfo(for: message)
        if let ref = message.tags["batch"], info?.isHistory == true {
            openBatches[ref]?.messageCount += 1
        }
        let line = ChatLine(
            timestamp: timestamp(from: message),
            sender: sender,
            text: body,
            kind: lineKind,
            isSelf: isSelf,
            account: message.tags["account"],
            msgid: message.tags["msgid"],
            replyTo: message.tags["+draft/reply"],
            isHistorical: info?.isHistory ?? false
        )
        let mentionsMe = isHighlight(body)
        buffer.append(line, markUnread: !isSelf)
        if mentionsMe && !isSelf && !line.isHistorical { buffer.hasMention = true }
        if !isSelf, !isNotice, !line.isHistorical {
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
        if isupport.equalIdentifiers(source.nick, currentNick) {
            buffer.isJoined = true
            // With no-implicit-names the roster arrives only when we ask; a fresh
            // join invalidates whatever we had, so re-fetch on next view.
            buffer.membersLoaded = false
            requestHistory(for: buffer)
        } else {
            // extended-join carries `JOIN <channel> <account> :<realname>`.
            let account = message.parameter(1).flatMap { $0 == "*" ? nil : $0 } ?? message.tags["account"]
            let realname = message.parameters.count >= 3 ? message.trailing : nil
            addMember(Member(nick: source.nick, prefix: nil, account: account, realname: realname), to: buffer)
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(source.nick) joined", kind: .event,
                                   presence: .join, presenceNick: source.nick), markUnread: false)
        }
    }

    private func handlePart(_ message: IRCMessage) {
        guard let channel = message.first, let source = message.source,
              let buffer = buffer(named: channel, kind: .channel, createIfMissing: false) else { return }
        if isupport.equalIdentifiers(source.nick, currentNick) {
            buffer.isJoined = false
        } else {
            removeMember(source.nick, from: buffer)
            buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                   text: "\(source.nick) left", kind: .event,
                                   presence: .part, presenceNick: source.nick), markUnread: false)
        }
    }

    private func handleQuit(_ message: IRCMessage) {
        guard let source = message.source else { return }
        for buffer in buffers where buffer.kind == .channel {
            if buffer.members.contains(where: { isupport.equalIdentifiers($0.nick, source.nick) }) {
                removeMember(source.nick, from: buffer)
                buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                       text: "\(source.nick) quit", kind: .event,
                                       presence: .quit, presenceNick: source.nick), markUnread: false)
            }
        }
    }

    private func handleNick(_ message: IRCMessage) {
        guard let source = message.source, let newNick = message.first else { return }
        if isupport.equalIdentifiers(source.nick, currentNick) { currentNick = newNick }
        for buffer in buffers where buffer.kind == .channel {
            if let idx = buffer.members.firstIndex(where: { isupport.equalIdentifiers($0.nick, source.nick) }) {
                buffer.members[idx].nick = newNick
                buffer.append(ChatLine(timestamp: timestamp(from: message), sender: nil,
                                       text: "\(source.nick) is now \(newNick)", kind: .event,
                                       presence: .nick, presenceNick: newNick), markUnread: false)
            }
        }
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

    // MARK: - Batches & soju extensions

    private func handleBatch(_ message: IRCMessage) {
        guard let reference = message.first else { return }
        if reference.hasPrefix("+") {
            let ref = String(reference.dropFirst())
            let type = message.parameter(1) ?? ""
            let isHistory = type == "chathistory"
            var info = BatchInfo(type: type, target: message.parameter(2), isHistory: isHistory)
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
            if let info = openBatches[ref], info.isHistory, let target = info.target,
               let buffer = buffer(named: target,
                                   kind: isupport.isChannel(target) ? .channel : .query,
                                   createIfMissing: false) {
                buffer.isLoadingHistory = false
                // A short page means we've reached the start of history.
                if info.messageCount < Self.historyPageSize { buffer.historyExhausted = true }
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
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : sender)
        let kind: Buffer.Kind = isupport.isChannel(target) ? .channel : .query
        guard let buffer = buffer(named: bufferName, kind: kind, createIfMissing: true) else { return }

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
            replyTo: info.multilineTags["+draft/reply"], isHistorical: historical)
        let mentionsMe = isHighlight(text)
        buffer.append(line, markUnread: !isSelf)
        if mentionsMe && !isSelf && !historical { buffer.hasMention = true }
        if !isSelf, !historical {
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
        guard enabledCaps.contains(CapabilityName.chathistory), !buffer.loadedHistory else { return }
        buffer.loadedHistory = true
        buffer.isLoadingHistory = true
        send(IRCMessage(command: "CHATHISTORY",
                        parameters: ["LATEST", buffer.name, "*", "\(Self.historyPageSize)"]))
    }

    /// Pulls an older page of scrollback (draft/chathistory `BEFORE`). Triggered
    /// when the user scrolls to the top of a conversation.
    func loadMoreHistory(for buffer: Buffer) {
        guard enabledCaps.contains(CapabilityName.chathistory),
              buffer.kind == .channel || buffer.kind == .query,
              !buffer.isLoadingHistory, !buffer.historyExhausted,
              let oldest = buffer.lines.first else { return }
        buffer.isLoadingHistory = true
        // Prefer the stable msgid; fall back to a timestamp selector.
        let selector = oldest.msgid.map { "msgid=\($0)" }
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
    /// `+draft/react` reaction.
    private func handleTagMsg(_ message: IRCMessage) {
        guard let target = message.first, let source = message.source else { return }
        let sender = source.nick
        let isSelf = isupport.equalIdentifiers(sender, currentNick)
        let bufferName = isupport.isChannel(target) ? target : (isSelf ? target : sender)
        guard let buffer = buffer(named: bufferName,
                                  kind: isupport.isChannel(target) ? .channel : .query,
                                  createIfMissing: false) else { return }

        if let emoji = message.tags["+draft/react"], let msgid = message.tags["+draft/reply"] {
            buffer.addReaction(emoji, toMsgID: msgid, from: sender)
        }
        if let emoji = message.tags["+draft/unreact"], let msgid = message.tags["+draft/reply"] {
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
        bufferIndex[key] = buffer
        buffers.append(buffer)
        return buffer
    }

    private func removeBuffer(_ buffer: Buffer) {
        guard buffer.kind != .status else { return }
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

    private func autoJoin() {
        for channel in config.autoJoinChannels where !channel.isEmpty {
            join(channel)
        }
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
