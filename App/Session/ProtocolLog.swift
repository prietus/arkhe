import Foundation
import Observation

/// A bounded, observable record of the raw IRC lines exchanged on a session —
/// the debug console. Credentials (`PASS`, `AUTHENTICATE` payloads) are redacted
/// before they're ever stored.
@MainActor
@Observable
final class ProtocolLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let outgoing: Bool
        let line: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 2000

    func append(_ line: String, outgoing: Bool, at date: Date = Date()) {
        entries.append(Entry(date: date, outgoing: outgoing, line: Self.redact(line)))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    func clear() { entries.removeAll() }

    /// Hides anything that would leak a secret on the wire.
    static func redact(_ line: String) -> String {
        if line.hasPrefix("PASS ") { return "PASS <redacted>" }
        if line.hasPrefix("AUTHENTICATE ") {
            let payload = line.dropFirst("AUTHENTICATE ".count)
            // The SASL handshake markers ("+"/numeric continuation) are safe;
            // the base64 credential blob is not.
            if payload != "+" { return "AUTHENTICATE <redacted>" }
        }
        return line
    }
}
