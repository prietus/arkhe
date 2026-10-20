import Testing
import Foundation
import IRCCore
@testable import Arkhe

/// Stands in for the network: records what the session sends and lets a test
/// feed server lines into it.
actor FakeTransport: IRCTransport {
    private var continuation: AsyncStream<IRCConnection.Event>.Continuation?
    private(set) var sent: [String] = []

    func open(_ endpoint: IRCConnection.Endpoint) -> AsyncStream<IRCConnection.Event> {
        let (stream, continuation) = AsyncStream<IRCConnection.Event>.makeStream()
        self.continuation = continuation
        continuation.yield(.ready)
        return stream
    }

    func send(_ message: IRCMessage) { sent.append(message.encoded()) }
    func disconnect() { continuation?.finish() }

    func receive(_ lines: String...) {
        for line in lines {
            guard let message = IRCMessage(parsing: line) else {
                Issue.record("unparseable test line: \(line)")
                continue
            }
            continuation?.yield(.message(message))
        }
    }
}

@MainActor
@Suite("IRCSession", .serialized)
struct SessionTests {
    let transport = FakeTransport()
    let session: IRCSession

    init() {
        session = IRCSession(config: SessionConfig(host: "irc.test", nickname: "me"),
                             transport: transport)
    }

    // MARK: - Helpers

    /// Polls until `condition` holds (the session handles events asynchronously).
    @discardableResult
    func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func sent(_ line: String) async -> Bool {
        await eventually { await transport.sent.contains(line) }
    }

    func count(_ line: String) async -> Int {
        await transport.sent.filter { $0 == line }.count
    }

    /// Connects and completes registration with chathistory and friends.
    /// `isupport` defaults to soju's: timestamp-only message references.
    func register(isupport: String = "MSGREFTYPES=timestamp", extraCaps: String = "") async {
        session.connect()
        #expect(await sent("CAP LS 302"))
        let caps = "batch draft/chathistory message-tags server-time" + (extraCaps.isEmpty ? "" : " " + extraCaps)
        await transport.receive(":srv CAP * LS :\(caps)", ":srv CAP * ACK :\(caps)",
                                ":srv 001 me :Welcome", ":srv 005 me \(isupport) :are supported")
        #expect(await eventually { session.status == .connected })
    }

    func buffer(_ name: String) -> Buffer? {
        session.buffers.first { $0.name == name }
    }

    static func time(_ seconds: Int) -> String {
        let date = Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(seconds))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `count` history PRIVMSGs inside batch `ref`, msgids `<prefix>0…`.
    static func page(_ ref: String, _ target: String, count: Int, prefix: String,
                     startSecond: Int = 0) -> [String] {
        (0..<count).map {
            "@batch=\(ref);msgid=\(prefix)\($0);time=\(time(startSecond + $0)) :alice!a@h PRIVMSG \(target) :line \($0)"
        }
    }

    func receive(_ lines: [String]) async {
        for line in lines { await transport.receive(line) }
    }

    // MARK: - draft/chathistory-end

    @Test("Without the end tag, a short page means start of history")
    func shortPageFallback() async {
        await register()
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        await receive([":srv BATCH +b1 chathistory #a"] + Self.page("b1", "#a", count: 3, prefix: "a")
                      + [":srv BATCH -b1"])
        #expect(await eventually { buffer("#a")?.historyExhausted == true })
        #expect(buffer("#a")?.lines.count == 3)
    }

    @Test("Once the server sends draft/chathistory-end, short pages no longer end history")
    func endTagIsAuthoritative() async {
        await register()
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        await receive(["@draft/chathistory-end :srv BATCH +b1 chathistory #a"]
                      + Self.page("b1", "#a", count: 2, prefix: "a") + [":srv BATCH -b1"])
        #expect(await eventually { buffer("#a")?.historyExhausted == true })

        await transport.receive(":me!u@h JOIN #b")
        #expect(await sent("CHATHISTORY LATEST #b * 100"))
        await receive([":srv BATCH +b2 chathistory #b"] + Self.page("b2", "#b", count: 2, prefix: "b")
                      + [":srv BATCH -b2"])
        #expect(await eventually { buffer("#b")?.lines.count == 2 })
        #expect(buffer("#b")?.historyExhausted == false)
    }

    // MARK: - On-device history + catch-up

    /// A snapshot of `#c` holding one message at second 0, round-tripped through
    /// JSON like `HistoryStore` does.
    func restoreOneLine() throws {
        let line = ChatLine(timestamp: Date(timeIntervalSince1970: 1_790_000_000), sender: "alice",
                            text: "old", kind: .message, msgid: "old0", isHistorical: true)
        let snapshot = HistoryStore.Snapshot(buffers: [
            .init(name: "#c", kind: .channel, topic: "t", readMarker: nil,
                  historyExhausted: false, lines: [line]),
        ])
        let decoded = try JSONDecoder().decode(HistoryStore.Snapshot.self,
                                               from: JSONEncoder().encode(snapshot))
        session.restoreHistory(decoded)
    }

    @Test("Restored scrollback catches up with AFTER and drops the overlap")
    func restoreCatchUp() async throws {
        try restoreOneLine()
        #expect(buffer("#c")?.lines.map(\.text) == ["old"])
        #expect(buffer("#c")?.topic == "t")

        await register()
        await transport.receive(":me!u@h JOIN #c")
        #expect(await sent("CHATHISTORY AFTER #c timestamp=\(Self.time(0)) 100"))
        #expect(await count("CHATHISTORY LATEST #c * 100") == 0)
        // The page repeats the restored message: it must not be duplicated.
        await receive([":srv BATCH +c1 chathistory #c",
                       "@batch=c1;msgid=old0;time=\(Self.time(0)) :alice!a@h PRIVMSG #c :old",
                       "@batch=c1;msgid=new0;time=\(Self.time(5)) :alice!a@h PRIVMSG #c :new",
                       ":srv BATCH -c1"])
        #expect(await eventually { buffer("#c")?.lines.count == 2 })
        #expect(buffer("#c")?.lines.map(\.text) == ["old", "new"])
        #expect(buffer("#c")?.historyExhausted == false)
    }

    @Test("A full catch-up page asks for the next one")
    func catchUpChains() async throws {
        try restoreOneLine()
        await register()
        await transport.receive(":me!u@h JOIN #c")
        #expect(await sent("CHATHISTORY AFTER #c timestamp=\(Self.time(0)) 100"))
        await receive([":srv BATCH +c1 chathistory #c"]
                      + Self.page("c1", "#c", count: 100, prefix: "n", startSecond: 1)
                      + [":srv BATCH -c1"])
        #expect(await sent("CHATHISTORY AFTER #c timestamp=\(Self.time(100)) 100"))
    }

    // MARK: - CHATHISTORY AROUND

    @Test("AROUND fills the context sheet, not the timeline")
    func aroundStaysOutOfTimeline() async throws {
        await register(isupport: "MSGREFTYPES=msgid,timestamp")
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        await receive([":srv BATCH +b1 chathistory #a"] + Self.page("b1", "#a", count: 1, prefix: "a", startSecond: 500)
                      + [":srv BATCH -b1"])
        let channel = try #require(await eventually { buffer("#a")?.isLoadingHistory == false } ? buffer("#a") : nil)

        session.showOriginal(of: "p1", in: channel)
        #expect(await sent("CHATHISTORY AROUND #a msgid=p1 30"))
        await receive([":srv BATCH +x chathistory #a",
                       "@batch=x;msgid=p0;time=\(Self.time(1)) :bob!b@h PRIVMSG #a :before",
                       "@batch=x;msgid=j0;time=\(Self.time(2)) :carol!c@h JOIN #a",
                       "@batch=x;msgid=p1;time=\(Self.time(3)) :bob!b@h PRIVMSG #a :original",
                       ":srv BATCH -x"])
        #expect(await eventually { session.aroundContext?.isLoading == false })
        #expect(session.aroundContext?.failed == false)
        #expect(session.aroundContext?.lines.map(\.text) == ["before", "original"])
        #expect(channel.lines.count == 1)
        #expect(channel.isLoadingHistory == false)
        #expect(channel.historyExhausted == true) // from the 1-line LATEST page, untouched by AROUND
    }

    @Test("FAIL on AROUND marks the context unavailable and unblocks history")
    func aroundFail() async throws {
        await register(isupport: "MSGREFTYPES=msgid,timestamp")
        await transport.receive(":me!u@h JOIN #a")
        await receive([":srv BATCH +b1 chathistory #a", ":srv BATCH -b1"])
        let channel = try #require(await eventually { buffer("#a")?.isLoadingHistory == false } ? buffer("#a") : nil)

        session.showOriginal(of: "zz", in: channel)
        #expect(await sent("CHATHISTORY AROUND #a msgid=zz 30"))
        await transport.receive(":srv FAIL CHATHISTORY INVALID_PARAMS AROUND :Unknown command")
        #expect(await eventually { session.aroundContext?.isLoading == false })
        #expect(session.aroundContext?.failed == true)
        #expect(channel.isLoadingHistory == false)
    }

    // MARK: - Timestamp-only servers (soju)

    /// Joins `#a` and lands one full LATEST page (seconds 1000…1099).
    func joinWithFullPage() async throws -> Buffer {
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        await receive([":srv BATCH +b1 chathistory #a"]
                      + Self.page("b1", "#a", count: 100, prefix: "a", startSecond: 1000)
                      + [":srv BATCH -b1"])
        return try #require(await eventually { buffer("#a")?.isLoadingHistory == false } ? buffer("#a") : nil)
    }

    @Test("Scroll-up uses a timestamp bound when msgid references aren't offered")
    func beforeUsesTimestamp() async throws {
        await register()
        let channel = try await joinWithFullPage()
        session.loadMoreHistory(for: channel)
        #expect(await sent("CHATHISTORY BEFORE #a timestamp=\(Self.time(1000)) 100"))
    }

    @Test("Scroll-up uses msgid where the server takes it")
    func beforeUsesMsgid() async throws {
        await register(isupport: "MSGREFTYPES=msgid,timestamp")
        let channel = try await joinWithFullPage()
        session.loadMoreHistory(for: channel)
        #expect(await sent("CHATHISTORY BEFORE #a msgid=a0 100"))
    }

    @Test("Without msgid references, the original is found by paging back")
    func seekPagesBack() async throws {
        await register()
        let channel = try await joinWithFullPage()
        session.showOriginal(of: "old5", in: channel)
        #expect(await sent("CHATHISTORY BEFORE #a timestamp=\(Self.time(1000)) 100"))
        #expect(await count("CHATHISTORY AROUND #a msgid=old5 30") == 0)
        // First older page doesn't contain it → another page is requested.
        await receive([":srv BATCH +p1 chathistory #a"]
                      + Self.page("p1", "#a", count: 100, prefix: "mid", startSecond: 900)
                      + [":srv BATCH -p1"])
        #expect(await sent("CHATHISTORY BEFORE #a timestamp=\(Self.time(900)) 100"))
        await receive([":srv BATCH +p2 chathistory #a"]
                      + Self.page("p2", "#a", count: 100, prefix: "old", startSecond: 800)
                      + [":srv BATCH -p2"])
        #expect(await eventually { session.jumpRequest != nil })
        let target = try #require(channel.lines.first { $0.msgid == "old5" })
        #expect(session.jumpRequest == .init(bufferID: channel.id, lineID: target.id))
    }

    @Test("A FAIL on scroll-up unblocks the buffer")
    func failUnblocksHistory() async throws {
        await register()
        let channel = try await joinWithFullPage()
        session.loadMoreHistory(for: channel)
        #expect(channel.isLoadingHistory)
        await transport.receive(":srv FAIL CHATHISTORY INVALID_PARAMS BEFORE x :Invalid first bound")
        #expect(await eventually { channel.isLoadingHistory == false })
    }

    // MARK: - Servers without msgids (soju)

    @Test("Restored lines without msgids still catch up, without duplicating the overlap")
    func catchUpWithoutMsgids() async throws {
        let line = ChatLine(timestamp: Date(timeIntervalSince1970: 1_790_000_000), sender: "alice",
                            text: "old", kind: .message, isHistorical: true)
        session.restoreHistory(.init(buffers: [
            .init(name: "#c", kind: .channel, topic: nil, readMarker: nil,
                  historyExhausted: false, lines: [line]),
        ]))
        await register()
        await transport.receive(":me!u@h JOIN #c")
        #expect(await sent("CHATHISTORY AFTER #c timestamp=\(Self.time(0)) 100"))
        await receive([":srv BATCH +c1 chathistory #c",
                       "@batch=c1;time=\(Self.time(0)) :alice!a@h PRIVMSG #c :old",
                       "@batch=c1;time=\(Self.time(5)) :bob!b@h PRIVMSG #c :new",
                       ":srv BATCH -c1"])
        #expect(await eventually { buffer("#c")?.lines.count == 2 })
        #expect(buffer("#c")?.lines.map(\.text) == ["old", "new"])
    }

    @Test("A restored buffer with nothing to anchor on falls back to LATEST")
    func restoredWithoutAnchorUsesLatest() async {
        let status = ChatLine(timestamp: Date(), sender: nil, text: "topic set", kind: .event)
        session.restoreHistory(.init(buffers: [
            .init(name: "#c", kind: .channel, topic: nil, readMarker: nil,
                  historyExhausted: false, lines: [status]),
        ]))
        await register()
        await transport.receive(":me!u@h JOIN #c")
        #expect(await sent("CHATHISTORY LATEST #c * 100"))
    }

    // MARK: - History page size

    @Test("A full page of mostly replayed events doesn't end history")
    func eventsCountTowardPageSize() async {
        await register()
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        // event-playback: 10 messages and 90 joins make a full 100-item page.
        let joins = (0..<90).map {
            "@batch=b1;time=\(Self.time(100 + $0)) :user\($0)!u@h JOIN #a"
        }
        await receive([":srv BATCH +b1 chathistory #a"] + Self.page("b1", "#a", count: 10, prefix: "a")
                      + joins + [":srv BATCH -b1"])
        #expect(await eventually { buffer("#a")?.isLoadingHistory == false })
        #expect(buffer("#a")?.historyExhausted == false)
    }

    @Test("Ignored CTCPs still count toward the page size")
    func ctcpCountsTowardPageSize() async {
        await register()
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        let ctcps = (0..<5).map {
            "@batch=b1;time=\(Self.time(200 + $0)) :bob!b@h PRIVMSG #a :\u{01}VERSION\u{01}"
        }
        await receive([":srv BATCH +b1 chathistory #a"] + Self.page("b1", "#a", count: 95, prefix: "a")
                      + ctcps + [":srv BATCH -b1"])
        #expect(await eventually { buffer("#a")?.isLoadingHistory == false })
        #expect(buffer("#a")?.lines.count == 95)
        #expect(buffer("#a")?.historyExhausted == false)
    }

    // MARK: - Status window

    @Test("SASL confirmations (900/903) aren't shown as errors; failures still are")
    func saslNumericsAreInformational() async {
        await register()
        await transport.receive(":srv 900 me me!u@h me :You are now logged in as me",
                                ":srv 903 me :SASL authentication successful",
                                ":srv 904 me :SASL authentication failed")
        let status = session.statusBuffer
        #expect(await eventually { status.lines.contains { $0.text.contains("failed") } })
        let kind = { (needle: String) in status.lines.first { $0.text.contains(needle) }?.kind }
        #expect(kind("logged in") == .event)
        #expect(kind("successful") == .event)
        #expect(kind("failed") == .error)
    }

    // MARK: - /ignore

    /// Registers, joins #a and lands an empty history page so live lines flow.
    func joinA() async throws -> Buffer {
        await register()
        await transport.receive(":me!u@h JOIN #a")
        #expect(await sent("CHATHISTORY LATEST #a * 100"))
        await receive([":srv BATCH +b1 chathistory #a", ":srv BATCH -b1"])
        return try #require(await eventually { buffer("#a")?.isLoadingHistory == false } ? buffer("#a") : nil)
    }

    func run(_ command: String, in buffer: Buffer) {
        session.sendText(command, to: buffer)
    }

    @Test("Ignored lines are kept but hidden, with no unread or notification; unignore restores them")
    func ignoreHidesAndRestores() async throws {
        defer { IgnoreStore.delete(session.config.id) }
        var notified = 0
        session.onNotifiableEvent = { _ in notified += 1 }
        let channel = try await joinA()
        run("/ignore Pepe", in: channel)
        #expect(session.ignores.map(\.pattern) == ["Pepe!*@*"])
        #expect(channel.lines.last?.text == "Ignoring Pepe!*@*.")

        await transport.receive(":pepe!p@host PRIVMSG #a :me: hello",
                                ":ana!a@host PRIVMSG #a :hi")
        #expect(await eventually { channel.lines.contains { $0.text == "hi" } })
        let pepe = try #require(channel.lines.first { $0.sender == "pepe" })
        #expect(session.isIgnored(pepe))
        #expect(channel.unreadCount == 1)      // only ana's line
        #expect(channel.hasMention == false)   // pepe's highlight didn't count
        #expect(notified == 0)

        run("/unignore pepe", in: channel)
        #expect(session.ignores.isEmpty)
        #expect(!session.isIgnored(pepe))
        #expect(channel.lines.last?.text == "No longer ignoring pepe!*@*.")
    }

    @Test("An ignored nick can't open a new private conversation")
    func ignoredDMDoesNotOpenQuery() async throws {
        defer { IgnoreStore.delete(session.config.id) }
        var notified = 0
        session.onNotifiableEvent = { _ in notified += 1 }
        let channel = try await joinA()
        run("/ignore spammer", in: channel)
        await transport.receive(":spammer!s@h PRIVMSG me :buy now",
                                ":friend!f@h PRIVMSG me :hey")
        #expect(await eventually { buffer("friend") != nil })
        #expect(buffer("spammer") == nil)
        #expect(notified == 1)
    }

    @Test("Hostmask and account rules match by host and by account")
    func ignoreByHostAndAccount() async throws {
        defer { IgnoreStore.delete(session.config.id) }
        let channel = try await joinA()
        run("/ignore *!*@bad.example", in: channel)
        run("/ignore $a:troll", in: channel)
        await transport.receive(":x!u@bad.example PRIVMSG #a :one",
                                "@account=troll :newnick!u@else PRIVMSG #a :two",
                                ":ok!u@good.example PRIVMSG #a :three")
        #expect(await eventually { channel.lines.contains { $0.text == "three" } })
        let ignored = channel.lines.filter { session.isIgnored($0) }.map(\.text)
        #expect(ignored == ["one", "two"])
    }

    @Test("Typing from an ignored nick is dropped")
    func ignoredTyping() async throws {
        defer { IgnoreStore.delete(session.config.id) }
        let channel = try await joinA()
        run("/ignore pepe", in: channel)
        await transport.receive("@+typing=active :pepe!p@h TAGMSG #a",
                                "@+typing=active :ana!a@h TAGMSG #a")
        #expect(await eventually { channel.typing["ana"] != nil })
        #expect(channel.typing["pepe"] == nil)
    }

    @Test("Ignores persist per server and bad masks are rejected")
    func ignorePersistence() async throws {
        defer { IgnoreStore.delete(session.config.id) }
        let channel = try await joinA()
        run("/ignore pepe", in: channel)
        run("/ignore pepe", in: channel)
        #expect(channel.lines.last?.text == "Already ignoring pepe!*@*.")
        run("/ignore a!b!c@d", in: channel)
        #expect(session.statusBuffer.lines.last?.kind == .error)
        run("/ignore", in: channel)
        #expect(channel.lines.last?.text == "Ignored: pepe!*@*")

        let again = IRCSession(config: session.config, transport: FakeTransport())
        #expect(again.ignores.map(\.pattern) == ["pepe!*@*"])
        // The notification extension reads every server's rules from the App Group.
        #expect(IgnoreStore.loadAll().map(\.pattern).contains("pepe!*@*"))
    }

    @Test("Phase-1 lists in the app's own defaults move to the shared store")
    func ignoreMigration() throws {
        let id = UUID()
        defer { IgnoreStore.delete(id) }
        let old = try JSONEncoder().encode([try #require(IgnoreMask(parsing: "legacy"))])
        UserDefaults.standard.set(old, forKey: "ignores.\(id.uuidString)")
        #expect(IgnoreStore.load(id).map(\.pattern) == ["legacy!*@*"])
        #expect(IgnoreStore.loadAll().map(\.pattern).contains("legacy!*@*"))
    }

    // MARK: - INVITE

    @Test("An invitation to us shows in status and notifies; an ignored inviter's doesn't")
    func inviteToUs() async throws {
        defer { IgnoreStore.delete(session.config.id) }
        var events: [NotifiableEvent] = []
        session.onNotifiableEvent = { events.append($0) }
        let channel = try await joinA()
        await transport.receive(":alice!a@h INVITE me #secret")
        let status = session.statusBuffer
        #expect(await eventually { status.lines.contains { $0.text == "alice invited you to #secret · /join #secret" } })
        #expect(events.map(\.kind) == [.invite])
        #expect(events.first?.conversation == "#secret")

        run("/ignore troll", in: channel)
        await transport.receive(":troll!t@h INVITE me #spam", ":bob!b@h INVITE me #ok")
        #expect(await eventually { status.lines.contains { $0.text.hasPrefix("bob invited you") } })
        #expect(!status.lines.contains { $0.text.contains("#spam") })
        #expect(events.count == 2)
    }

    @Test("invite-notify shows in the channel; /invite sends and 341 confirms")
    func inviteNotifyAndCommand() async throws {
        let channel = try await joinA()
        await transport.receive(":op!o@h INVITE carol #a")
        #expect(await eventually { channel.lines.contains { $0.text == "op invited carol" } })

        run("/invite dave", in: channel)
        #expect(await sent("INVITE dave #a"))
        await transport.receive(":srv 341 me dave #a")
        #expect(await eventually { channel.lines.last?.text == "Invited dave to #a." })

        run("/invite", in: channel)
        #expect(session.statusBuffer.lines.last?.kind == .error)
    }

    // MARK: - MONITOR

    @Test("Open queries are monitored after registration; presence and away update")
    func monitorQueries() async throws {
        await register(isupport: "MONITOR=100 MSGREFTYPES=timestamp")
        await transport.receive(":bob!b@h PRIVMSG me :hi")
        let bob = try #require(await eventually { buffer("bob") != nil } ? buffer("bob") : nil)
        // Nothing until registration ends (ISUPPORT may still be arriving).
        #expect(await count("MONITOR + bob") == 0)
        await transport.receive(":srv 422 me :MOTD File is missing")
        #expect(await sent("MONITOR + bob"))

        await transport.receive(":srv 730 me :bob!b@h")
        #expect(await eventually { bob.peerOnline == true })
        await transport.receive(":bob!b@h AWAY :lunch")
        #expect(await eventually { bob.peerAway })
        await transport.receive(":srv 731 me :bob")
        #expect(await eventually { bob.peerOnline == false })
        #expect(!bob.peerAway)

        run("/query carol", in: bob)
        #expect(await sent("MONITOR + carol"))
        session.part(bob)
        #expect(await sent("MONITOR - bob"))
    }

    @Test("Without MONITOR in ISUPPORT nothing is sent and presence stays unknown")
    func noMonitor() async throws {
        await register()
        await transport.receive(":bob!b@h PRIVMSG me :hi", ":srv 376 me :End of MOTD")
        let bob = try #require(await eventually { buffer("bob") != nil } ? buffer("bob") : nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sent.allSatisfy { !$0.hasPrefix("MONITOR") })
        #expect(bob.peerOnline == nil)
    }

    @Test("The MONITOR limit is respected")
    func monitorLimit() async {
        await register(isupport: "MONITOR=1 MSGREFTYPES=timestamp")
        await transport.receive(":a!a@h PRIVMSG me :1", ":b!b@h PRIVMSG me :2", ":srv 376 me :End")
        #expect(await sent("MONITOR + a"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sent.filter { $0.hasPrefix("MONITOR") } == ["MONITOR + a"])
    }

    // MARK: - Web Push

    @Test("The IRCv3 draft/webpush works like soju.im/webpush (Ergo)")
    func draftWebPush() async {
        var ready = 0
        session.onWebPushReady = { ready += 1 }
        await register(extraCaps: "draft/webpush")
        #expect(session.supportsWebPush)
        #expect(ready == 1)
        session.registerWebPush(endpoint: "https://push.example/v1/t", p256dh: "P", auth: "A")
        #expect(await sent("WEBPUSH REGISTER https://push.example/v1/t p256dh=P;auth=A"))
    }
}
