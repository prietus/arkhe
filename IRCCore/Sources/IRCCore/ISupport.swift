import Foundation

/// The server's case-folding rule for nicknames and channel names, from the
/// `CASEMAPPING` ISUPPORT token.
public enum CaseMapping: String, Sendable {
    case ascii
    case rfc1459
    case rfc1459Strict = "rfc1459-strict"

    /// Case-folds `input` according to the mapping. IRC treats `{}|` (and, for
    /// non-strict rfc1459, `^`) as the lowercase of `[]\` (and `~`).
    public func fold(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch (self, scalar) {
            case (_, "A"..."Z"):
                result.unicodeScalars.append(Unicode.Scalar(scalar.value + 32)!)
            case (.rfc1459, "["), (.rfc1459Strict, "["):
                result.append("{")
            case (.rfc1459, "]"), (.rfc1459Strict, "]"):
                result.append("}")
            case (.rfc1459, "\\"), (.rfc1459Strict, "\\"):
                result.append("|")
            case (.rfc1459, "~"):
                result.append("^")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// Parsed `RPL_ISUPPORT` (005) tokens describing server limits and features.
public struct ISupport: Sendable {
    public private(set) var tokens: [String: String] = [:]

    public init() {}

    /// Folds two identifiers and compares them under the server's casemapping.
    public func equalIdentifiers(_ a: String, _ b: String) -> Bool {
        caseMapping.fold(a) == caseMapping.fold(b)
    }

    /// Merges the tokens from one `005` line. Negated tokens (`-NAME`) are
    /// removed, resetting to default.
    public mutating func apply(_ message: IRCMessage) {
        // params: <nick> TOKEN[=value] ... :are supported by this server
        for param in message.parameters.dropFirst() {
            if param.hasPrefix(":") || param.lowercased().contains("supported by") { continue }
            if param.hasPrefix("-") {
                tokens[String(param.dropFirst())] = nil
                continue
            }
            if let eq = param.firstIndex(of: "=") {
                tokens[String(param[..<eq])] = String(param[param.index(after: eq)...])
            } else {
                tokens[param] = ""
            }
        }
    }

    public var caseMapping: CaseMapping {
        CaseMapping(rawValue: tokens["CASEMAPPING"] ?? "rfc1459") ?? .rfc1459
    }

    public var network: String? {
        tokens["NETWORK"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Channel-type prefixes (default `#&`).
    public var channelTypes: String { tokens["CHANTYPES"] ?? "#&" }

    /// `true` when `name` begins with a channel-type prefix.
    public func isChannel(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return channelTypes.contains(first)
    }

    /// Parsed `PREFIX=(modes)symbols`, e.g. `(ov)@+` → [("o","@"),("v","+")].
    public var prefixes: [(mode: Character, symbol: Character)] {
        guard let raw = tokens["PREFIX"],
              raw.hasPrefix("("),
              let close = raw.firstIndex(of: ")") else {
            return [("o", "@"), ("v", "+")]
        }
        let modes = Array(raw[raw.index(after: raw.startIndex)..<close])
        let symbols = Array(raw[raw.index(after: close)...])
        return zip(modes, symbols).map { ($0, $1) }
    }

    /// The set of membership prefix symbols (e.g. `@`, `+`).
    public var prefixSymbols: Set<Character> { Set(prefixes.map(\.symbol)) }

    /// The user mode letter that marks an account as a bot (IRCv3 Bot Mode),
    /// from the `BOT` ISUPPORT token (e.g. `BOT=B`). `nil` when unsupported.
    public var botMode: Character? {
        tokens["BOT"].flatMap { $0.count == 1 ? $0.first : nil }
    }

    /// Whether the server will relay the given client-only tag between users,
    /// per `CLIENTTAGDENY` (IRCv3 message-tags). The tag name is given without
    /// the leading `+` (e.g. `draft/react`, `typing`).
    ///
    /// `CLIENTTAGDENY` is a comma-separated list: `*` denies all client tags,
    /// `-name` is an allow-exception, and a bare `name` denies that one. Later
    /// matching entries win, so `*,-typing` denies everything except `typing`.
    public func allowsClientTag(_ name: String) -> Bool {
        guard let deny = tokens["CLIENTTAGDENY"], !deny.isEmpty else { return true }
        var denied = false
        for entry in deny.split(separator: ",") {
            if entry == "*" {
                denied = true
            } else if entry.hasPrefix("-") {
                if entry.dropFirst() == Substring(name) { denied = false }
            } else if entry == Substring(name) {
                denied = true
            }
        }
        return !denied
    }
}
