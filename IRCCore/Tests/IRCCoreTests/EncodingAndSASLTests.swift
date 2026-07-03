import Testing
import Foundation
@testable import IRCCore

@Suite("Message encoding")
struct EncodingTests {
    @Test("Round-trips a typical message")
    func roundTrip() throws {
        let line = ":nick!u@h PRIVMSG #chan :hello world"
        let msg = try #require(IRCMessage(parsing: line))
        #expect(msg.encoded() == line)
    }

    @Test("Trailing param gets colon when it has spaces")
    func trailingColon() {
        let msg = IRCMessage.privmsg("#c", "two words")
        #expect(msg.encoded() == "PRIVMSG #c :two words")
    }

    @Test("Single-word trailing keeps no colon")
    func singleWord() {
        let msg = IRCMessage.privmsg("#c", "word")
        #expect(msg.encoded() == "PRIVMSG #c word")
    }

    @Test("Empty trailing param gets a colon")
    func emptyTrailing() {
        let msg = IRCMessage(command: "PART", parameters: ["#c", ""])
        #expect(msg.encoded() == "PART #c :")
    }

    @Test("Tags serialise sorted and escaped")
    func tagSerialise() {
        let msg = IRCMessage(tags: ["b": "x y", "a": "1"], command: "PING")
        #expect(msg.encoded() == "@a=1;b=x\\sy PING")
    }

    @Test("wireData appends CRLF")
    func wire() {
        let msg = IRCMessage.pong("token")
        #expect(msg.wireData() == Data("PONG token\r\n".utf8))
    }
}

@Suite("SASL")
struct SASLTests {
    @Test("PLAIN initial response layout")
    func plainResponse() throws {
        let data = try #require(SASL.initialResponse(for: .plain(authcid: "alice", password: "s3cret")))
        // authzid \0 authcid \0 password — authzid empty
        let expected = Data([0]) + Data("alice".utf8) + Data([0]) + Data("s3cret".utf8)
        #expect(data == expected)
    }

    @Test("PLAIN base64 payload")
    func plainBase64() {
        let response = SASL.initialResponse(for: .plain(authcid: "alice", password: "pass"))!
        let payloads = SASL.chunkedPayloads(for: response)
        #expect(payloads == [response.base64EncodedString()])
        #expect(Data(base64Encoded: payloads[0]) == response)
    }

    @Test("EXTERNAL empty authzid encodes to +")
    func externalEmpty() {
        let response = SASL.initialResponse(for: .external())!
        #expect(response.isEmpty)
        #expect(SASL.chunkedPayloads(for: response) == ["+"])
    }

    @Test("Payload exactly 400 bytes gets a + terminator")
    func chunkBoundary() {
        // 300 raw bytes → 400 base64 chars exactly.
        let raw = Data(repeating: 0x41, count: 300)
        let payloads = SASL.chunkedPayloads(for: raw)
        #expect(payloads.count == 2)
        #expect(payloads[0].count == 400)
        #expect(payloads[1] == "+")
    }

    @Test("Challenge decoding")
    func challenge() {
        #expect(SASL.decodeChallenge("+") == Data())
        #expect(SASL.decodeChallenge(Data("hi".utf8).base64EncodedString()) == Data("hi".utf8))
    }
}

@Suite("Case mapping")
struct CaseMappingTests {
    @Test("rfc1459 folds brace characters")
    func rfc1459() {
        let m = CaseMapping.rfc1459
        #expect(m.fold("Nick[]\\~") == "nick{}|^")
        #expect(m.fold("ABC") == "abc")
    }

    @Test("ascii leaves braces alone")
    func ascii() {
        #expect(CaseMapping.ascii.fold("Nick[]") == "nick[]")
    }

    @Test("ISupport identifier comparison")
    func isupport() throws {
        var s = ISupport()
        let msg = try #require(IRCMessage(parsing: "005 me CASEMAPPING=ascii CHANTYPES=#& NETWORK=Test :are supported"))
        s.apply(msg)
        #expect(s.network == "Test")
        #expect(s.isChannel("#chan"))
        #expect(!s.isChannel("nick"))
        #expect(s.equalIdentifiers("Alice", "alice"))
    }
}
