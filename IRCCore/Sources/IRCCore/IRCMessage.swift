import Foundation

/// A parsed IRC protocol message following the IRCv3 message format:
///
///     ['@' <tags> SPACE] [':' <source> SPACE] <command> <parameters> <crlf>
///
/// `IRCMessage` is an immutable value type. Parse the wire format with
/// `IRCMessage(parsing:)` and produce it with `encoded()`.
public struct IRCMessage: Sendable, Equatable {
    /// IRCv3 message tags (`@key=value;...`). Empty when absent.
    public var tags: [String: String]

    /// The message source / prefix (`nick!user@host` or a server name), if present.
    public var source: IRCSource?

    /// The command verb, uppercased for word commands (`PRIVMSG`) or a 3-digit
    /// numeric reply (`001`).
    public var command: String

    /// Command parameters. The trailing parameter (after `:`) is included here
    /// like any other; the encoder re-adds the `:` automatically when needed.
    public var parameters: [String]

    public init(
        tags: [String: String] = [:],
        source: IRCSource? = nil,
        command: String,
        parameters: [String] = []
    ) {
        self.tags = tags
        self.source = source
        self.command = command
        self.parameters = parameters
    }

    /// A 3-digit numeric reply code, if this message carries one.
    public var numeric: IRCNumeric? {
        guard command.count == 3, let code = Int(command) else { return nil }
        return IRCNumeric(rawValue: code)
    }
}

// MARK: - Convenience accessors

public extension IRCMessage {
    /// First parameter, or `nil` if there are none.
    var first: String? { parameters.first }

    /// Last parameter (commonly the message text / trailing parameter).
    var trailing: String? { parameters.last }

    /// Returns the parameter at `index`, or `nil` if out of range.
    func parameter(_ index: Int) -> String? {
        parameters.indices.contains(index) ? parameters[index] : nil
    }
}
