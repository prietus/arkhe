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

    @Test("FILEHOST: draft name wins, soju vendor name as fallback")
    func fileHostNames() {
        #expect(isupport("soju.im/FILEHOST=https://bnc.example/uploads")
            .fileHost(allowInsecure: false)?.absoluteString == "https://bnc.example/uploads")
        #expect(isupport("soju.im/FILEHOST=https://a.example/x draft/FILEHOST=https://b.example/y")
            .fileHost(allowInsecure: false)?.host == "b.example")
        #expect(isupport("NETWORK=Example").fileHost(allowInsecure: true) == nil)
    }

    @Test("FILEHOST: plain http only over a plaintext IRC link")
    func fileHostScheme() {
        let s = isupport("soju.im/FILEHOST=http://192.168.1.34:8080/uploads")
        #expect(s.fileHost(allowInsecure: false) == nil)
        #expect(s.fileHost(allowInsecure: true)?.port == 8080)
        #expect(isupport("draft/FILEHOST=ftp://x.example/").fileHost(allowInsecure: true) == nil)
    }

    @Test("FILEHOST: \\xHH escapes are decoded")
    func fileHostEscapes() {
        let s = isupport("draft/FILEHOST=https://x.example/up?a\\x3Db")
        #expect(s.fileHost(allowInsecure: false)?.query == "a=b")
    }
}
