import Testing
import Foundation
@testable import IRCCore

@Suite("ISUPPORT parsing")
struct ISupportTests {
    /// Builds an ISupport from a single 005 line's tokens.
    private func isupport(_ tokens: String) -> ISupport {
        var s = ISupport()
        s.apply(IRCMessage(parsing: ":server 005 nick \(tokens) :are supported by this server")!)
        return s
    }

    @Test("No CLIENTTAGDENY allows every client tag")
    func noDenyAllowsAll() {
        let s = isupport("NETWORK=Example CHANTYPES=#")
        #expect(s.allowsClientTag("draft/react"))
        #expect(s.allowsClientTag("typing"))
    }

    @Test("Star denies all client tags")
    func starDeniesAll() {
        let s = isupport("CLIENTTAGDENY=*")
        #expect(!s.allowsClientTag("draft/react"))
        #expect(!s.allowsClientTag("typing"))
    }

    @Test("Libera's *,-typing: only typing is relayed")
    func starExceptTyping() {
        let s = isupport("CLIENTTAGDENY=*,-typing")
        #expect(s.allowsClientTag("typing"))
        #expect(!s.allowsClientTag("draft/react"))
        #expect(!s.allowsClientTag("draft/reply"))
    }

    @Test("Bare names deny only those tags")
    func bareNamesDeny() {
        let s = isupport("CLIENTTAGDENY=draft/react,draft/reply")
        #expect(!s.allowsClientTag("draft/react"))
        #expect(!s.allowsClientTag("draft/reply"))
        #expect(s.allowsClientTag("typing"))
    }

    @Test("BOT token exposes the bot user-mode letter")
    func botModeLetter() {
        #expect(isupport("BOT=B NETWORK=Example").botMode == "B")
        #expect(isupport("NETWORK=Example").botMode == nil)
        // A malformed multi-character value is ignored.
        #expect(isupport("BOT=XY").botMode == nil)
    }
}
