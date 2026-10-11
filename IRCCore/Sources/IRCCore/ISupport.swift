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

    /// `MSGREFTYPES`: the message reference types `CHATHISTORY` accepts, in the
    /// server's order of preference (e.g. Ergo `msgid,timestamp`, soju
    /// `timestamp`). Empty when not advertised.
    public var messageReferenceTypes: [String] {
        tokens["MSGREFTYPES"].map { $0.split(separator: ",").map(String.init) } ?? []
    }

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

    /// The server's recommended upload endpoint (IRCv3 `filehost`, still a work
    /// in progress): `draft/FILEHOST`, or soju's vendor `soju.im/FILEHOST`.
    /// Only `https` is returned, plus `http` when `allowInsecure` (the IRC link
    /// itself is plaintext) — the spec forbids downgrading a TLS connection.
    public func fileHost(allowInsecure: Bool) -> URL? {
        guard let raw = tokens["draft/FILEHOST"] ?? tokens["soju.im/FILEHOST"],
              let url = URL(string: Self.unescapeValue(raw)),
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" || (scheme == "http" && allowInsecure) { return url }
        return nil
    }

    /// Decodes the `\xHH` escapes ISUPPORT values use for bytes like space and `=`.
    static func unescapeValue(_ value: String) -> String {
        guard value.contains("\\x") else { return value }
        var bytes: [UInt8] = []
        let utf8 = Array(value.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "\\"), i + 3 < utf8.count, utf8[i + 1] == UInt8(ascii: "x"),
               let byte = UInt8(String(decoding: utf8[(i + 2)...(i + 3)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                i += 4
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
