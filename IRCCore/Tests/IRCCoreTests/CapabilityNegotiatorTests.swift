import Testing
import Foundation
@testable import IRCCore

@Suite("Capability negotiation")
struct CapabilityNegotiatorTests {
    private func parse(_ lines: String...) -> [IRCMessage] {
        lines.compactMap { IRCMessage(parsing: $0) }
    }

    @Test("start sends CAP LS 302")
    func start() {
        var neg = CapabilityNegotiator()
        let out = neg.start()
        #expect(out.map { $0.encoded() } == ["CAP LS 302"])
        #expect(neg.phase == .listing)
    }

    @Test("Without SASL: REQ then END")
    func noSASL() throws {
        var neg = CapabilityNegotiator()
        _ = neg.start()
        let ls = try #require(IRCMessage(parsing: ":srv CAP * LS :server-time message-tags batch sasl"))
        let req = neg.handle(ls)
        // sasl should NOT be requested without credentials.
        let reqMsg = try #require(req.first)
        #expect(reqMsg.command == "CAP")
        #expect(reqMsg.parameters[0] == "REQ")
        #expect(!reqMsg.parameters[1].contains("sasl"))
        #expect(reqMsg.parameters[1].contains("server-time"))

        let ack = try #require(IRCMessage(parsing: ":srv CAP * ACK :server-time message-tags batch"))
        let end = neg.handle(ack)
        #expect(end.map { $0.encoded() } == ["CAP END"])
        #expect(neg.isFinished)
        #expect(neg.enabled.contains("server-time"))
    }

    @Test("SASL PLAIN full handshake")
    func saslPlain() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "alice", password: "pw"))
        _ = neg.start()

        let ls = try #require(IRCMessage(parsing: ":srv CAP * LS :sasl=PLAIN,EXTERNAL server-time"))
        let req = neg.handle(ls)
        #expect(req.first?.parameters[1].contains("sasl") == true)

        let ack = try #require(IRCMessage(parsing: ":srv CAP * ACK :sasl server-time"))
        let auth = neg.handle(ack)
        #expect(auth.map { $0.encoded() } == ["AUTHENTICATE PLAIN"])
        #expect(neg.phase == .authenticating)

        // Server prompts for the payload.
        let prompt = try #require(IRCMessage(parsing: "AUTHENTICATE +"))
        let payloads = neg.handle(prompt)
        #expect(payloads.count == 1)
        #expect(payloads[0].command == "AUTHENTICATE")
        let decoded = Data(base64Encoded: payloads[0].parameters[0])
        #expect(decoded == SASL.initialResponse(for: .plain(authcid: "alice", password: "pw")))

        // Success → CAP END.
        let success = try #require(IRCMessage(parsing: ":srv 903 alice :SASL authentication successful"))
        let end = neg.handle(success)
        #expect(end.map { $0.encoded() } == ["CAP END"])
        #expect(neg.saslResult == .succeeded)
        #expect(neg.isFinished)
    }

    @Test("SASL EXTERNAL (CertFP) handshake")
    func saslExternal() throws {
        var neg = CapabilityNegotiator(mechanism: .external())
        _ = neg.start()
        _ = neg.handle(try #require(IRCMessage(parsing: ":srv CAP * LS :sasl=EXTERNAL")))
        let auth = neg.handle(try #require(IRCMessage(parsing: ":srv CAP * ACK :sasl")))
        #expect(auth.map { $0.encoded() } == ["AUTHENTICATE EXTERNAL"])
        let payloads = neg.handle(try #require(IRCMessage(parsing: "AUTHENTICATE +")))
        #expect(payloads.map { $0.encoded() } == ["AUTHENTICATE +"])
        let end = neg.handle(try #require(IRCMessage(parsing: ":srv 903 me :ok")))
        #expect(end.map { $0.encoded() } == ["CAP END"])
        #expect(neg.saslResult == .succeeded)
    }

    @Test("SASL failure still ends negotiation")
    func saslFailure() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "a", password: "b"))
        _ = neg.start()
        _ = neg.handle(try #require(IRCMessage(parsing: ":srv CAP * LS :sasl=PLAIN")))
        _ = neg.handle(try #require(IRCMessage(parsing: ":srv CAP * ACK :sasl")))
        _ = neg.handle(try #require(IRCMessage(parsing: "AUTHENTICATE +")))
        let end = neg.handle(try #require(IRCMessage(parsing: ":srv 904 a :SASL authentication failed")))
        #expect(end.map { $0.encoded() } == ["CAP END"])
        if case .failed = neg.saslResult {} else { Issue.record("expected failure") }
    }

    @Test("Multi-line CAP LS continuation")
    func multiLineLS() throws {
        var neg = CapabilityNegotiator()
        _ = neg.start()
        let first = neg.handle(try #require(IRCMessage(parsing: ":srv CAP * LS * :server-time batch")))
        #expect(first.isEmpty) // waiting for continuation
        let second = neg.handle(try #require(IRCMessage(parsing: ":srv CAP * LS :message-tags")))
        #expect(second.first?.command == "CAP")
        #expect(neg.available.count == 3)
    }
}
