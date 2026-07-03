import Foundation

/// The origin of an IRC message — either a user (`nick!user@host`) or a
/// server name. Parsed from the message prefix (the `:`-led token).
public struct IRCSource: Sendable, Equatable {
    /// The nickname or server name. For a server source, `user` and `host`
    /// are `nil` and this holds the server name.
    public var name: String
    /// The ident / username (after `!`), if present.
    public var user: String?
    /// The hostname (after `@`), if present.
    public var host: String?

    public init(name: String, user: String? = nil, host: String? = nil) {
        self.name = name
        self.user = user
        self.host = host
    }

    /// `true` when this source looks like a user (has a `!user` or `@host`
    /// component, or simply isn't a dotted server name).
    public var isUser: Bool {
        user != nil || host != nil || !name.contains(".")
    }

    /// The nickname when this source represents a user.
    public var nick: String { name }

    /// Parses a raw prefix string such as `nick!user@host`, `nick@host`,
    /// `nick` or `irc.example.org`.
    public init(parsing raw: Substring) {
        var name = raw
        var user: String?
        var host: String?

        if let at = name.firstIndex(of: "@") {
            host = String(name[name.index(after: at)...])
            name = name[..<at]
        }
        if let bang = name.firstIndex(of: "!") {
            user = String(name[name.index(after: bang)...])
            name = name[..<bang]
        }
        self.init(name: String(name), user: user, host: host)
    }

    /// The canonical `nick!user@host` rendering (omitting absent components).
    public var raw: String {
        var result = name
        if let user { result += "!\(user)" }
        if let host { result += "@\(host)" }
        return result
    }
}

extension IRCSource: CustomStringConvertible {
    public var description: String { raw }
}
