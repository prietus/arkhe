import Testing
@testable import IRCCore

@Suite("STS policy")
struct STSPolicyTests {
    @Test("Parses port, duration and preload; ignores unknown keys")
    func parses() {
        let p = STSPolicy(value: "duration=86400,port=6697,preload,future=x")
        #expect(p.port == 6697)
        #expect(p.duration == 86400)
        #expect(p.preload)
    }

    @Test("Invalid or missing parts are absent")
    func invalid() {
        let p = STSPolicy(value: "port=abc,duration=-5")
        #expect(p.port == nil)
        #expect(p.duration == nil)
        #expect(STSPolicy(value: nil) == STSPolicy(value: ""))
        #expect(STSPolicy(value: "duration=0").duration == 0)
    }
}
