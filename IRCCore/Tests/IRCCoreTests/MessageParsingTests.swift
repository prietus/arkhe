import Testing
import Foundation
@testable import IRCCore

@Suite("IRCv3 message parsing")
struct MessageParsingTests {
    @Test("Simple command with trailing")
    func simpleTrailing() throws {
        let msg = try #require(IRCMessage(parsing: "PRIVMSG #chan :hello world"))
        #expect(msg.command == "PRIVMSG")
        #expect(msg.parameters == ["#chan", "hello world"])
        #expect(msg.source == nil)
        #expect(msg.tags.isEmpty)
    }

    @Test("Source prefix nick!user@host")
    func sourcePrefix() throws {
        let msg = try #require(IRCMessage(parsing: ":nick!ident@host.tld PRIVMSG #c :hi"))
        let src = try #require(msg.source)
        #expect(src.nick == "nick")
        #expect(src.user == "ident")
        #expect(src.host == "host.tld")
        #expect(src.isUser)
    }

    @Test("Server source is not a user")
    func serverSource() throws {
        let msg = try #require(IRCMessage(parsing: ":irc.example.org 001 me :Welcome"))
        let src = try #require(msg.source)
        #expect(src.name == "irc.example.org")
        #expect(!src.isUser)
        #expect(msg.numeric == .welcome)
    }

    @Test("Tags with escaping")
    func tagsEscaping() throws {
        let raw = "@time=2023-01-01T00:00:00.000Z;+example/foo=bar\\sbaz;account=alice :n!u@h PRIVMSG #c :yo"
        let msg = try #require(IRCMessage(parsing: raw))
        #expect(msg.tags["time"] == "2023-01-01T00:00:00.000Z")
        #expect(msg.tags["+example/foo"] == "bar baz")
        #expect(msg.tags["account"] == "alice")
    }

    @Test("Tag escape sequences decode correctly")
    func tagEscapeSequences() {
        #expect(IRCTagEscaping.unescape("a\\:b\\sc\\\\d\\r\\ne") == "a;b c\\d\r\ne")
        #expect(IRCTagEscaping.unescape("plain") == "plain")
        #expect(IRCTagEscaping.unescape("trailing\\") == "trailing")
        #expect(IRCTagEscaping.unescape("\\x") == "x") // unknown escape → literal
    }

    @Test("Valueless tag")
    func valuelessTag() throws {
        let msg = try #require(IRCMessage(parsing: "@draft/typing PRIVMSG #c :x"))
        #expect(msg.tags["draft/typing"] == "")
    }

    @Test("Empty / whitespace lines return nil")
    func emptyLine() {
        #expect(IRCMessage(parsing: "") == nil)
        #expect(IRCMessage(parsing: "    ") == nil)
        #expect(IRCMessage(parsing: "\r") == nil)
    }

    @Test("Multiple middle params without trailing")
    func middleParams() throws {
        let msg = try #require(IRCMessage(parsing: "MODE #chan +o someuser"))
        #expect(msg.parameters == ["#chan", "+o", "someuser"])
    }

    @Test("Trailing colon preserved in content")
    func trailingWithColon() throws {
        let msg = try #require(IRCMessage(parsing: "PRIVMSG #c ::-) emoticon"))
        #expect(msg.trailing == ":-) emoticon")
    }

    @Test("CR stripped from line end")
    func stripCR() throws {
        let msg = try #require(IRCMessage(parsing: "PING :token\r"))
        #expect(msg.trailing == "token")
    }
}
