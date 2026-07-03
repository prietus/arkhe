import Foundation

/// Drives IRCv3 capability negotiation and the SASL exchange as a pure state
/// machine: feed it inbound `CAP` / `AUTHENTICATE` / numeric messages and it
/// returns the messages to send back. It performs no I/O, which keeps it
/// fully unit-testable independent of the transport.
///
/// Flow: `CAP LS 302` → collect advertised caps → `CAP REQ` the intersection
/// with the desired set → on `ACK`, run SASL if configured/available → on SASL
/// completion (or if SASL isn't used) send `CAP END`.
public struct CapabilityNegotiator: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case listing            // sent CAP LS, collecting advertised caps
        case requesting         // sent CAP REQ, awaiting ACK/NAK
        case authenticating     // SASL in progress
        case finished           // CAP END sent
    }

    /// The outcome of SASL, surfaced to the session driver.
    public enum SASLResult: Sendable, Equatable {
        case notAttempted
        case succeeded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var available: [Capability] = []
    public private(set) var enabled: Set<String> = []
    public private(set) var saslResult: SASLResult = .notAttempted

    private let desired: Set<String>
    private let mechanism: SASLMechanism?
    private var pendingLS: [Capability] = []
    private var requested: Set<String> = []

    public init(desired: Set<String> = CapabilityName.desired, mechanism: SASLMechanism? = nil) {
        // Only request `sasl` when we actually have credentials to offer.
        if mechanism == nil {
            self.desired = desired.subtracting([CapabilityName.sasl])
        } else {
            self.desired = desired
        }
        self.mechanism = mechanism
    }

    public var isFinished: Bool { phase == .finished }

    /// Returns the opening message(s) — begins capability negotiation.
    public mutating func start() -> [IRCMessage] {
        phase = .listing
        return [.capLS()]
    }

    /// Feeds one inbound message into the negotiator and returns any messages
    /// to send in response.
    public mutating func handle(_ message: IRCMessage) -> [IRCMessage] {
        switch message.command {
        case "CAP":
            return handleCAP(message)
        case "AUTHENTICATE":
            return handleAuthenticate(message)
        default:
            if let numeric = message.numeric { return handleNumeric(numeric, message) }
            return []
        }
    }

    // MARK: - CAP

    private mutating func handleCAP(_ message: IRCMessage) -> [IRCMessage] {
        // params: <target> <subcommand> [*] [<caps>]
        guard message.parameters.count >= 2 else { return [] }
        let sub = message.parameters[1].uppercased()
        switch sub {
        case "LS":
            return handleLS(message)
        case "ACK":
            return handleACK(message)
        case "NAK":
            return handleNAK(message)
        case "NEW":
            // cap-notify: server offers new caps post-registration.
            let caps = capabilityList(from: message, after: 2)
            available.append(contentsOf: caps)
            let toReq = caps.map(\.name).filter { desired.contains($0) }
            return toReq.isEmpty ? [] : [.capReq(toReq)]
        case "DEL":
            let caps = capabilityList(from: message, after: 2)
            for cap in caps { enabled.remove(cap.name) }
            return []
        default:
            return []
        }
    }

    private mutating func handleLS(_ message: IRCMessage) -> [IRCMessage] {
        // <target> LS [*] :<caps>
        let hasMore = message.parameters.count >= 4 && message.parameters[2] == "*"
        let capsIndex = hasMore ? 3 : 2
        pendingLS.append(contentsOf: capabilityList(from: message, after: capsIndex - 1))

        guard !hasMore else { return [] } // wait for the continuation line
        available = pendingLS
        pendingLS = []

        let requestable = available.map(\.name).filter { desired.contains($0) }
        requested = Set(requestable)
        guard !requestable.isEmpty else {
            return finish()
        }
        phase = .requesting
        return [.capReq(requestable.sorted())]
    }

    private mutating func handleACK(_ message: IRCMessage) -> [IRCMessage] {
        let caps = capabilityList(from: message, after: 1)
        for cap in caps { enabled.insert(cap.name) }

        // If SASL was negotiated and we have a usable mechanism, start it.
        if enabled.contains(CapabilityName.sasl), let mechanism, saslSupported(mechanism) {
            phase = .authenticating
            return [.authenticate(mechanism.name)]
        }
        return finish()
    }

    private mutating func handleNAK(_ message: IRCMessage) -> [IRCMessage] {
        // Server refused the requested caps; proceed without them.
        return finish()
    }

    // MARK: - SASL

    private mutating func handleAuthenticate(_ message: IRCMessage) -> [IRCMessage] {
        guard phase == .authenticating, let mechanism else { return [] }
        // Server prompts with `AUTHENTICATE +` (or a challenge). For PLAIN and
        // EXTERNAL we always reply with our (pre-computed) response.
        let payload = message.first ?? "+"
        _ = SASL.decodeChallenge(payload) // challenge ignored for PLAIN/EXTERNAL
        guard let response = SASL.initialResponse(for: mechanism) else { return [] }
        return SASL.chunkedPayloads(for: response).map { .authenticate($0) }
    }

    private mutating func handleNumeric(_ numeric: IRCNumeric, _ message: IRCMessage) -> [IRCMessage] {
        guard phase == .authenticating else { return [] }
        switch numeric {
        case .saslSuccess, .loggedIn:
            if numeric == .saslSuccess {
                saslResult = .succeeded
                return finish()
            }
            return [] // loggedIn (900) precedes 903; wait for success
        case .saslFail, .saslTooLong, .saslAborted, .nickLocked, .saslAlready:
            saslResult = .failed(message.trailing ?? numeric.description)
            return finish()
        default:
            return []
        }
    }

    // MARK: - Helpers

    private mutating func finish() -> [IRCMessage] {
        guard phase != .finished else { return [] }
        phase = .finished
        return [.capEnd()]
    }

    private func saslSupported(_ mechanism: SASLMechanism) -> Bool {
        guard let cap = available.first(where: { $0.name == CapabilityName.sasl }) else {
            return true // server didn't enumerate mechanisms; assume supported
        }
        let mechs = cap.values
        return mechs.isEmpty || mechs.contains(mechanism.name)
    }

    private func capabilityList(from message: IRCMessage, after index: Int) -> [Capability] {
        guard message.parameters.indices.contains(index + 1) else { return [] }
        return message.parameters[index + 1]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(Capability.init(token:))
    }
}

extension IRCNumeric: CustomStringConvertible {
    public var description: String { String(rawValue) }
}
