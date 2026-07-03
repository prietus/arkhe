import Foundation
import Network
import IRCCore

/// Low-level IRC transport over `NWConnection`: establishes a TLS connection
/// (optionally presenting a client certificate for CertFP), frames the byte
/// stream on CRLF, and surfaces parsed `IRCMessage`s through an `AsyncStream`.
///
/// It knows nothing about IRC semantics beyond line framing — registration,
/// CAP and SASL live in `IRCSession`.
actor IRCConnection {
    enum Event: Sendable {
        case connecting
        case ready
        case message(IRCMessage)
        case error(String)
        case closed
        /// A raw protocol line exactly as sent/received (for the debug console).
        case raw(line: String, outgoing: Bool)
    }

    struct Endpoint: Sendable {
        var host: String
        var port: UInt16
        var useTLS: Bool
        /// Accept self-signed / untrusted server certificates (common for
        /// personal soju instances). Use with care.
        var allowInvalidCertificates: Bool
        /// Client identity for CertFP / SASL EXTERNAL, if configured.
        var clientIdentity: TLSIdentity?

        init(host: String, port: UInt16, useTLS: Bool = true,
             allowInvalidCertificates: Bool = false, clientIdentity: TLSIdentity? = nil) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
            self.allowInvalidCertificates = allowInvalidCertificates
            self.clientIdentity = clientIdentity
        }
    }

    private let queue = DispatchQueue(label: "im.arkhe.irc.connection")
    private var connection: NWConnection?
    private var continuation: AsyncStream<Event>.Continuation?
    private var readBuffer = Data()
    /// Hard cap so a server that never sends CRLF can't grow the buffer forever.
    private let maxLineLength = 8192 * 2

    /// Opens the connection and returns the event stream. The stream finishes
    /// when the connection closes or errors.
    func open(_ endpoint: Endpoint) -> AsyncStream<Event> {
        let parameters = makeParameters(endpoint)
        let nwHost = NWEndpoint.Host(endpoint.host)
        let nwPort = NWEndpoint.Port(rawValue: endpoint.port) ?? 6697
        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = connection

        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.connecting)

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleState(state) }
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.cancel() }
            }
            connection.start(queue: self.queue)
        }
    }

    /// Serialises and sends a message (appending CRLF).
    func send(_ message: IRCMessage) {
        let line = message.encoded()
        continuation?.yield(.raw(line: line, outgoing: true))
        connection?.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    func disconnect() {
        cancel()
    }

    // MARK: - Connection state

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            continuation?.yield(.ready)
            receiveLoop()
        case let .failed(error):
            continuation?.yield(.error(error.localizedDescription))
            finish()
        case .cancelled:
            finish()
        case let .waiting(error):
            continuation?.yield(.error("Waiting for network: \(error.localizedDescription)"))
        default:
            break
        }
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            ingest(data)
        }
        if let error {
            continuation?.yield(.error(error.localizedDescription))
            finish()
            return
        }
        if isComplete {
            finish()
            return
        }
        receiveLoop()
    }

    /// Appends bytes and emits a `.message` for each complete CRLF/LF line.
    private func ingest(_ data: Data) {
        readBuffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let index = readBuffer.firstIndex(of: newline) {
            let lineData = readBuffer[readBuffer.startIndex..<index]
            readBuffer.removeSubrange(readBuffer.startIndex...index)
            guard let line = String(data: lineData, encoding: .utf8)
                    ?? String(data: lineData, encoding: .isoLatin1) else { continue }
            let rawLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
            continuation?.yield(.raw(line: rawLine, outgoing: false))
            if let message = IRCMessage(parsing: line) {
                continuation?.yield(.message(message))
            }
        }
        if readBuffer.count > maxLineLength {
            readBuffer.removeAll(keepingCapacity: false)
            continuation?.yield(.error("Protocol line too long; discarded."))
        }
    }

    private func cancel() {
        connection?.cancel()
        connection = nil
    }

    private func finish() {
        continuation?.yield(.closed)
        continuation?.finish()
        continuation = nil
        connection = nil
    }

    // MARK: - TLS parameters

    private func makeParameters(_ endpoint: Endpoint) -> NWParameters {
        guard endpoint.useTLS else {
            return NWParameters.tcp
        }
        let tlsOptions = NWProtocolTLS.Options()
        let sec = tlsOptions.securityProtocolOptions

        // Present a client certificate for CertFP, if one is configured.
        if let identity = endpoint.clientIdentity,
           let secIdentity = sec_identity_create(identity.secIdentity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
            sec_protocol_options_set_challenge_block(sec, { _, complete in
                complete(secIdentity)
            }, queue)
        }

        if endpoint.allowInvalidCertificates {
            sec_protocol_options_set_verify_block(sec, { _, _, complete in
                complete(true) // trust everything — opt-in only
            }, queue)
        }

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }
}
