import Testing
import Foundation
@testable import IRCCore

@Suite("SCRAM-SHA-256")
struct SCRAMTests {
    // RFC 7677 §3 test vector.
    private let nonce = "rOprNGfwEbeRWgbNEkqO"
    private let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private let clientFinal = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
    private let serverFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    private func message(_ line: String) throws -> IRCMessage {
        try #require(IRCMessage(parsing: line))
    }

    private func authenticate(_ text: String) -> String {
        "AUTHENTICATE " + Data(text.utf8).base64EncodedString()
    }

    @Test("RFC 7677 vector: client-first, proof and server signature")
    func rfcVector() throws {
        var client = SCRAMClient(username: "user", password: "pencil", nonce: nonce)
        #expect(String(decoding: client.clientFirst(), as: UTF8.self) == "n,,n=user,r=\(nonce)")
        let final = client.clientFinal(serverFirst: Data(serverFirst.utf8))
        #expect(final.map { String(decoding: $0, as: UTF8.self) } == clientFinal)
        #expect(client.verify(serverFinal: Data(serverFinal.utf8)))
        #expect(!client.verify(serverFinal: Data("v=AAAA".utf8)))
    }

    @Test("Rejects a server nonce that doesn't extend ours")
    func rejectsForeignNonce() {
        var client = SCRAMClient(username: "user", password: "pencil", nonce: nonce)
        _ = client.clientFirst()
        #expect(client.clientFinal(serverFirst: Data("r=somethingElse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8)) == nil)
    }

    @Test("Escapes = and , in the username")
    func escapesUsername() {
        #expect(SCRAMClient.escape("a=b,c") == "a=3Db=2Cc")
    }

    @Test("Negotiator upgrades PLAIN to SCRAM-SHA-256 and completes")
    func negotiatorUpgrade() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "user", password: "pencil"),
                                       scramNonce: nonce)
        _ = neg.start()
        _ = neg.handle(try message(":srv CAP * LS :sasl=PLAIN,SCRAM-SHA-256"))
        #expect(neg.handle(try message(":srv CAP * ACK :sasl")).map { $0.encoded() }
                == ["AUTHENTICATE SCRAM-SHA-256"])
        #expect(neg.handle(try message("AUTHENTICATE +")).map { $0.encoded() }
                == [authenticate("n,,n=user,r=\(nonce)")])
        #expect(neg.handle(try message(authenticate(serverFirst))).map { $0.encoded() }
                == [authenticate(clientFinal)])
        #expect(neg.handle(try message(authenticate(serverFinal))).map { $0.encoded() }
                == ["AUTHENTICATE +"])
        #expect(neg.handle(try message(":srv 903 user :SASL authentication successful")).map { $0.encoded() }
                == ["CAP END"])
        #expect(neg.saslResult == .succeeded)
    }

    @Test("Without SCRAM on offer, PLAIN stays PLAIN")
    func plainWhenNoScram() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "user", password: "pencil"))
        _ = neg.start()
        _ = neg.handle(try message(":srv CAP * LS :sasl=PLAIN"))
        #expect(neg.handle(try message(":srv CAP * ACK :sasl")).map { $0.encoded() } == ["AUTHENTICATE PLAIN"])
    }

    @Test("A SCRAM 904 retries once with PLAIN")
    func fallsBackToPlain() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "user", password: "pencil"),
                                       scramNonce: nonce)
        _ = neg.start()
        _ = neg.handle(try message(":srv CAP * LS :sasl=PLAIN,SCRAM-SHA-256"))
        _ = neg.handle(try message(":srv CAP * ACK :sasl"))
        _ = neg.handle(try message("AUTHENTICATE +"))
        #expect(neg.handle(try message(":srv 904 user :SASL authentication failed")).map { $0.encoded() }
                == ["AUTHENTICATE PLAIN"])
        #expect(neg.activeMechanism?.name == "PLAIN")
        // A second failure is final.
        #expect(neg.handle(try message(":srv 904 user :SASL authentication failed")).map { $0.encoded() }
                == ["CAP END"])
        #expect(neg.saslResult == .failed("SASL authentication failed"))
    }

    @Test("A forged server signature aborts without falling back")
    func forgedSignatureAborts() throws {
        var neg = CapabilityNegotiator(mechanism: .plain(authcid: "user", password: "pencil"),
                                       scramNonce: nonce)
        _ = neg.start()
        _ = neg.handle(try message(":srv CAP * LS :sasl=SCRAM-SHA-256,PLAIN"))
        _ = neg.handle(try message(":srv CAP * ACK :sasl"))
        _ = neg.handle(try message("AUTHENTICATE +"))
        _ = neg.handle(try message(authenticate(serverFirst)))
        let forged = authenticate("v=" + Data(repeating: 0, count: 32).base64EncodedString())
        #expect(neg.handle(try message(forged)).map { $0.encoded() } == ["AUTHENTICATE *", "CAP END"])
        #expect(neg.saslResult == .failed("SCRAM server signature mismatch"))
        #expect(neg.isFinished)
    }
}
