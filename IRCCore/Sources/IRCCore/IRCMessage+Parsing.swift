import Foundation

public extension IRCMessage {
    /// Parses a single line of the IRC wire protocol (without the trailing
    /// CRLF). Returns `nil` for an empty / whitespace-only line.
    ///
    /// Grammar:
    ///
    ///     ['@' <tags> SPACE] [':' <source> SPACE] <command> { SPACE <param> } [SPACE ':' <trailing>]
    init?(parsing line: some StringProtocol) {
        var rest = Substring(line)
        // Some servers may include a trailing CR if the caller split on LF only.
        if rest.last == "\r" { rest = rest.dropLast() }
        rest = rest.drop { $0 == " " }
        guard !rest.isEmpty else { return nil }

        var tags: [String: String] = [:]
        var source: IRCSource?

        // Tags
        if rest.first == "@" {
            rest = rest.dropFirst()
            guard let space = rest.firstIndex(of: " ") else { return nil }
            tags = IRCTagBlock.parse(rest[..<space])
            rest = rest[rest.index(after: space)...].drop { $0 == " " }
        }

        // Source / prefix
        if rest.first == ":" {
            rest = rest.dropFirst()
            guard let space = rest.firstIndex(of: " ") else { return nil }
            source = IRCSource(parsing: rest[..<space])
            rest = rest[rest.index(after: space)...].drop { $0 == " " }
        }

        // Command
        guard !rest.isEmpty else { return nil }
        let command: String
        if let space = rest.firstIndex(of: " ") {
            command = String(rest[..<space])
            rest = rest[rest.index(after: space)...]
        } else {
            command = String(rest)
            rest = rest[rest.endIndex...]
        }
        guard !command.isEmpty else { return nil }

        // Parameters
        var parameters: [String] = []
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " }
            if rest.isEmpty { break }
            if rest.first == ":" {
                // Trailing parameter: rest of the line verbatim.
                parameters.append(String(rest.dropFirst()))
                break
            }
            if let space = rest.firstIndex(of: " ") {
                parameters.append(String(rest[..<space]))
                rest = rest[rest.index(after: space)...]
            } else {
                parameters.append(String(rest))
                break
            }
        }

        self.init(
            tags: tags,
            source: source,
            command: command.uppercased(),
            parameters: parameters
        )
    }
}
