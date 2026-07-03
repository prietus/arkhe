import Foundation

/// Factory helpers for the outgoing messages the client sends. These keep
/// command spelling and parameter order in one place.
public extension IRCMessage {
    static func cap(_ subcommand: String, _ args: String...) -> IRCMessage {
        IRCMessage(command: "CAP", parameters: [subcommand] + args)
    }

    static func capLS() -> IRCMessage {
        IRCMessage(command: "CAP", parameters: ["LS", "302"])
    }

    static func capReq(_ caps: [String]) -> IRCMessage {
        IRCMessage(command: "CAP", parameters: ["REQ", caps.joined(separator: " ")])
    }

    static func capEnd() -> IRCMessage {
        IRCMessage(command: "CAP", parameters: ["END"])
    }

    static func authenticate(_ payload: String) -> IRCMessage {
        IRCMessage(command: "AUTHENTICATE", parameters: [payload])
    }

    static func nick(_ nick: String) -> IRCMessage {
        IRCMessage(command: "NICK", parameters: [nick])
    }

    static func user(_ user: String, realName: String) -> IRCMessage {
        IRCMessage(command: "USER", parameters: [user, "0", "*", realName])
    }

    static func pass(_ password: String) -> IRCMessage {
        IRCMessage(command: "PASS", parameters: [password])
    }

    static func pong(_ token: String) -> IRCMessage {
        IRCMessage(command: "PONG", parameters: [token])
    }

    static func ping(_ token: String) -> IRCMessage {
        IRCMessage(command: "PING", parameters: [token])
    }

    static func join(_ channel: String, key: String? = nil) -> IRCMessage {
        IRCMessage(command: "JOIN", parameters: key.map { [channel, $0] } ?? [channel])
    }

    static func part(_ channel: String, reason: String? = nil) -> IRCMessage {
        IRCMessage(command: "PART", parameters: reason.map { [channel, $0] } ?? [channel])
    }

    static func privmsg(_ target: String, _ text: String) -> IRCMessage {
        IRCMessage(command: "PRIVMSG", parameters: [target, text])
    }

    static func notice(_ target: String, _ text: String) -> IRCMessage {
        IRCMessage(command: "NOTICE", parameters: [target, text])
    }

    /// A tag-only message (IRCv3 `message-tags`). Carries client-only tags such
    /// as `+typing`, `+draft/react` / `+draft/reply` with no text body.
    static func tagmsg(_ target: String, tags: [String: String]) -> IRCMessage {
        IRCMessage(tags: tags, command: "TAGMSG", parameters: [target])
    }

    static func setname(_ realName: String) -> IRCMessage {
        IRCMessage(command: "SETNAME", parameters: [realName])
    }

    /// Opens a client batch of the given type (IRCv3 `batch`), e.g. a
    /// `draft/multiline` send. `reference` is a short token unique on this link.
    static func batchOpen(_ reference: String, type: String, target: String? = nil) -> IRCMessage {
        IRCMessage(command: "BATCH", parameters: ["+\(reference)", type] + (target.map { [$0] } ?? []))
    }

    static func batchClose(_ reference: String) -> IRCMessage {
        IRCMessage(command: "BATCH", parameters: ["-\(reference)"])
    }

    static func quit(_ reason: String? = nil) -> IRCMessage {
        IRCMessage(command: "QUIT", parameters: reason.map { [$0] } ?? [])
    }

    static func names(_ channel: String) -> IRCMessage {
        IRCMessage(command: "NAMES", parameters: [channel])
    }
}
