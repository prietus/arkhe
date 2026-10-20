import Testing
import Foundation
import IRCCore
@testable import Arkhe

/// soju metadata sync: exact-nick ignores (`soju.im/blocked`), mutes
/// (`soju.im/muted`) and pins (`soju.im/pinned`).
@MainActor
@Suite("soju metadata sync", .serialized)
struct BlockSyncTests {
    let id = UUID()
    let transport = FakeTransport()

    /// A session bound to one soju network, created after the store is seeded.
    func makeSession(local: [String] = [], synced: Set<String> = [],
                     muted: Set<String> = [], mutedSynced: Set<String> = []) -> IRCSession {
        IgnoreStore.save(local.compactMap { IgnoreMask(parsing: $0) }, for: id)
        IgnoreStore.saveSynced(synced, for: id)
        TargetFlagStore.save(muted, .muted, id)
        TargetFlagStore.saveSynced(mutedSynced, .muted, id)
        return IRCSession(config: SessionConfig(id: id, host: "bnc.test", nickname: "me",
                                                username: "me/libera"),
                          transport: transport)
    }

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

    /// Registers as soju would answer, then plays back its current block list.
    func connect(_ session: IRCSession, caps: String = "batch message-tags server-time draft/metadata-2 soju.im/no-implicit-names",
                 serverState: [String] = []) async {
        session.connect()
        #expect(await sent("CAP LS 302"))
        // Like soju: bouncer-networks is offered but not taken on a bound connection.
        await transport.receive(":srv CAP * LS :\(caps) soju.im/bouncer-networks", ":srv CAP * ACK :\(caps)",
                                ":srv 001 me :Welcome")
        #expect(await eventually { session.status == .connected })
        guard caps.contains("draft/metadata-2") else { return }
        #expect(await sent("METADATA * SUB soju.im/blocked soju.im/muted soju.im/pinned"))
        for line in serverState { await transport.receive(line) }
        await transport.receive(":srv 770 me soju.im/blocked", ":srv 770 me soju.im/muted",
                                ":srv 770 me soju.im/pinned")
        #expect(await eventually { session.isMetadataSynced })
    }

    func rules(_ session: IRCSession) -> Set<String> { Set(session.ignores.map(\.pattern)) }

    @Test("Initial sync is a three-way merge with the last synced state")
    func threeWayMerge() async {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        // Local: a (on soju last time), b (added here while away).
        // soju:  c (blocked from another client), d (on soju last time).
        let session = makeSession(local: ["a", "b"], synced: ["a", "d"])
        await connect(session, serverState: [
            ":srv METADATA c soju.im/blocked * 1",
            ":srv METADATA d soju.im/blocked * 1",
            ":srv METADATA e soju.im/blocked * 0",
        ])
        // a: unblocked elsewhere → dropped here. c: imported. b → pushed. d → unblocked on soju.
        #expect(await eventually { rules(session) == ["b!*@*", "c!*@*"] })
        #expect(await sent("METADATA b SET soju.im/blocked 1"))
        #expect(await sent("METADATA d SET soju.im/blocked 0"))
        #expect(IgnoreStore.loadSynced(id) == ["b", "c"])
    }

    @Test("After the sync, /ignore and /unignore update soju; masks and accounts stay local")
    func liveOutbound() async throws {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        let session = makeSession()
        await connect(session)
        #expect(await eventually { IgnoreStore.loadSynced(id).isEmpty })
        let status = session.statusBuffer
        session.sendText("/ignore Pepe", to: status)
        #expect(await sent("METADATA Pepe SET soju.im/blocked 1"))
        session.sendText("/ignore *!*@bad.example", to: status)
        session.sendText("/ignore $a:troll", to: status)
        session.sendText("/unignore pepe", to: status)
        #expect(await sent("METADATA Pepe SET soju.im/blocked 0"))
        let metadata = await transport.sent.filter { $0.hasPrefix("METADATA") && !$0.contains("SUB") }
        #expect(metadata.count == 2)
        #expect(rules(session) == ["*!*@bad.example", "$a:troll"])
    }

    @Test("Blocks and unblocks from other clients apply live; channels are ignored")
    func liveInbound() async {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        let session = makeSession()
        await connect(session)
        await transport.receive(":srv METADATA spammer soju.im/blocked * 1",
                                ":srv METADATA #chan soju.im/blocked * 1")
        #expect(await eventually { rules(session) == ["spammer!*@*"] })
        await transport.receive(":srv METADATA spammer soju.im/blocked * 0")
        #expect(await eventually { session.ignores.isEmpty })
        // Only the live inbound changes: nothing echoed back to soju.
        #expect(await transport.sent.filter { $0.contains("SET") }.isEmpty)
    }

    @Test("Without metadata (or not bound to a network) nothing is synced")
    func noSyncWithoutSupport() async {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        let session = makeSession(local: ["a"])
        await connect(session, caps: "batch message-tags server-time soju.im/no-implicit-names")
        session.sendText("/ignore b", to: session.statusBuffer)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await transport.sent.allSatisfy { !$0.hasPrefix("METADATA") })
        #expect(rules(session) == ["a!*@*", "b!*@*"])
    }

    // MARK: - muted / pinned

    @Test("Mutes merge three ways like ignores, per server")
    func mutedMerge() async {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        // Local: #a (synced before), #b (muted here while away).
        // soju:  #c (muted elsewhere), #d (synced before).
        let session = makeSession(muted: ["#a", "#b"], mutedSynced: ["#a", "#d"])
        await connect(session, serverState: [
            ":srv METADATA #C soju.im/muted * 1",
            ":srv METADATA #d soju.im/muted * 1",
        ])
        #expect(await eventually { session.mutedTargets == ["#b", "#c"] })
        #expect(await sent("METADATA #b SET soju.im/muted 1"))
        #expect(await sent("METADATA #d SET soju.im/muted 0"))
        #expect(session.isMuted("#C"))
        #expect(TargetFlagStore.load(.muted, id) == ["#b", "#c"])
        #expect(TargetFlagStore.loadSynced(.muted, id) == ["#b", "#c"])
    }

    @Test("Pin and mute changes go to soju live; other clients' changes apply")
    func pinAndMuteLive() async {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        let session = makeSession()
        await connect(session)
        #expect(await eventually { TargetFlagStore.loadSynced(.pinned, id).isEmpty })
        session.setPinned(true, for: "#Soju")
        #expect(await sent("METADATA #Soju SET soju.im/pinned 1"))
        #expect(session.isPinned("#soju"))
        session.setMuted(true, for: "bob")
        #expect(await sent("METADATA bob SET soju.im/muted 1"))

        await transport.receive(":srv METADATA #soju soju.im/pinned * 0",
                                ":srv METADATA #archlinux soju.im/pinned * 1")
        #expect(await eventually { session.pinnedTargets == ["#archlinux"] })
        // Mutes and pins accept channels (only blocks are nick-only).
        #expect(TargetFlagStore.load(.pinned, id) == ["#archlinux"])
    }

    @Test("Offline, mute and pin stay local and the next connect pushes them")
    func offlineThenSync() async {
        defer { IgnoreStore.delete(id); TargetFlagStore.delete(id) }
        let session = makeSession()
        session.setMuted(true, for: "#quiet")
        #expect(await transport.sent.isEmpty)
        await connect(session)
        #expect(await sent("METADATA #quiet SET soju.im/muted 1"))
    }

    @Test("A legacy global mute list seeds a server once")
    func legacyMuteSeed() {
        defer { TargetFlagStore.delete(id) }
        TargetFlagStore.seedIfAbsent(.muted, id, with: ["#Old"])
        #expect(TargetFlagStore.load(.muted, id) == ["#old"])
        TargetFlagStore.save([], .muted, id)
        TargetFlagStore.seedIfAbsent(.muted, id, with: ["#Old"])
        #expect(TargetFlagStore.load(.muted, id).isEmpty)   // an emptied list isn't re-seeded
    }
}
