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
    func register(isupport: String = "MSGREFTYPES=timestamp") async {
        session.connect()
        #expect(await sent("CAP LS 302"))
        let caps = "batch draft/chathistory message-tags server-time"
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
}
