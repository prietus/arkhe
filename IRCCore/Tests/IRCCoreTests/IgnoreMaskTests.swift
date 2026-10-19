import Testing
@testable import IRCCore

@Suite("Ignore masks")
struct IgnoreMaskTests {
    private func mask(_ input: String) -> String? { IgnoreMask(parsing: input)?.pattern }

    @Test("Shorthands expand to full hostmasks")
    func expansion() {
        #expect(mask("pepe") == "pepe!*@*")
        #expect(mask("pepe!ident") == "pepe!ident@*")
        #expect(mask("ident@host.example") == "*!ident@host.example")
        #expect(mask("*!*@user/pepe") == "*!*@user/pepe")
        #expect(mask("$a:pepe") == "$a:pepe")
        #expect(mask("  pepe  ") == "pepe!*@*")
    }

    @Test("Malformed input is rejected")
    func rejects() {
        #expect(mask("") == nil)
        #expect(mask("two words") == nil)
        #expect(mask("a!b!c@d") == nil)
        #expect(mask("a!b@c@d") == nil)
        #expect(mask("!user@host") == nil)
        #expect(mask("$a:") == nil)
    }

    @Test("Nick masks match case-insensitively under the network casemapping")
    func nickMatch() throws {
        let m = try #require(IgnoreMask(parsing: "Pepe"))
        #expect(m.matches(nick: "pepe", user: "u", host: "h", account: nil, caseMapping: .rfc1459))
        #expect(!m.matches(nick: "pepe2", user: "u", host: "h", account: nil, caseMapping: .rfc1459))
        // rfc1459 folds [ ] \ ~ to { } | ^.
        let bracket = try #require(IgnoreMask(parsing: "nick[a]"))
        #expect(bracket.matches(nick: "NICK{A}", user: nil, host: nil, account: nil, caseMapping: .rfc1459))
        #expect(!bracket.matches(nick: "NICK{A}", user: nil, host: nil, account: nil, caseMapping: .ascii))
    }

    @Test("Wildcards in host and user")
    func wildcards() throws {
        let m = try #require(IgnoreMask(parsing: "*!*@*.example.com"))
        #expect(m.matches(nick: "a", user: "x", host: "pc1.example.com", account: nil, caseMapping: .ascii))
        #expect(!m.matches(nick: "a", user: "x", host: "example.org", account: nil, caseMapping: .ascii))
        let q = try #require(IgnoreMask(parsing: "bot?"))
        #expect(q.matches(nick: "bot1", user: nil, host: nil, account: nil, caseMapping: .ascii))
        #expect(!q.matches(nick: "bot12", user: nil, host: nil, account: nil, caseMapping: .ascii))
    }

    @Test("Unknown user/host only match a wildcard")
    func missingParts() throws {
        let byHost = try #require(IgnoreMask(parsing: "*!*@user/pepe"))
        #expect(!byHost.matches(nick: "pepe", user: nil, host: nil, account: nil, caseMapping: .ascii))
        let byNick = try #require(IgnoreMask(parsing: "pepe"))
        #expect(byNick.matches(nick: "pepe", user: nil, host: nil, account: nil, caseMapping: .ascii))
    }

    @Test("Account rules follow the account across nicks")
    func accounts() throws {
        let m = try #require(IgnoreMask(parsing: "$a:Pepe"))
        #expect(m.isAccount)
        #expect(m.matches(nick: "anything", user: nil, host: nil, account: "pepe", caseMapping: .ascii))
        #expect(!m.matches(nick: "pepe", user: nil, host: nil, account: nil, caseMapping: .ascii))
        #expect(!m.matches(nick: "x", user: nil, host: nil, account: "pepe2", caseMapping: .ascii))
    }

    @Test("plainNick names only exact single-nick rules")
    func plainNick() {
        #expect(IgnoreMask(parsing: "pepe")?.plainNick == "pepe")
        #expect(IgnoreMask(parsing: "pep*")?.plainNick == nil)
        #expect(IgnoreMask(parsing: "pepe!*@host")?.plainNick == nil)
        #expect(IgnoreMask(parsing: "$a:pepe")?.plainNick == nil)
    }
}
