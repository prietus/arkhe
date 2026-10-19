import Foundation

/// A client-side ignore rule, the classic `/ignore`: either a hostmask
/// `nick!user@host` with `*` / `?` wildcards, or an account `$a:name` (from
/// `account-tag` / `extended-join`), which survives nick changes and new hosts.
///
/// Shorthands are expanded the way IRC clients always have:
/// `pepe` → `pepe!*@*`, `pepe!u` → `pepe!u@*`, `u@host` → `*!u@host`.
public struct IgnoreMask: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The normalized rule: `nick!user@host` or `$a:account`.
    public let pattern: String

    public init?(parsing input: String) {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        if raw.lowercased().hasPrefix("$a:") {
            let account = raw.dropFirst(3)
            guard !account.isEmpty else { return nil }
            pattern = "$a:" + account
            return
        }
        var mask = raw
        if !mask.contains("!") {
            mask = mask.contains("@") ? "*!" + mask : mask + "!*"
        }
        if !mask.contains("@") { mask += "@*" }
        // Exactly one `!` before exactly one `@`, each part non-empty.
        let bang = mask.split(separator: "!", omittingEmptySubsequences: false)
        guard bang.count == 2, !bang[0].isEmpty else { return nil }
        let at = bang[1].split(separator: "@", omittingEmptySubsequences: false)
        guard at.count == 2, !at[0].isEmpty, !at[1].isEmpty else { return nil }
        pattern = mask
    }

    public var description: String { pattern }

    /// An account rule (`$a:`) rather than a hostmask.
    public var isAccount: Bool { pattern.hasPrefix("$a:") }

    /// The nick this rule names exactly (`pepe!*@*` → `pepe`), for menus that
    /// offer to un-ignore someone; `nil` for wider masks and accounts.
    public var plainNick: String? {
        guard !isAccount, pattern.hasSuffix("!*@*") else { return nil }
        let nick = String(pattern.dropLast(4))
        return nick.contains(where: { $0 == "*" || $0 == "?" }) ? nil : nick
    }

    /// Whether a sender matches. Missing user/host/account (e.g. a line kept
    /// from before they were known) only match a `*` in that position.
    public func matches(nick: String, user: String?, host: String?, account: String?,
                        caseMapping: CaseMapping) -> Bool {
        if isAccount {
            guard let account else { return false }
            return Self.glob(caseMapping.fold(String(pattern.dropFirst(3))), caseMapping.fold(account))
        }
        let subject = "\(nick)!\(user ?? "")@\(host ?? "")"
        return Self.glob(caseMapping.fold(pattern), caseMapping.fold(subject))
    }

    /// Wildcard match: `*` is any run (including empty), `?` one character.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
