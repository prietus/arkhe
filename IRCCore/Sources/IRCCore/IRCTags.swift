import Foundation

/// IRCv3 message-tag value escaping, per the `message-tags` specification.
///
/// On the wire, tag values escape five characters:
///
///     ;  -> \:      (space) -> \s      \ -> \\      CR -> \r      LF -> \n
///
/// An unrecognised escape (`\x`) decodes to the literal character, and a
/// dangling trailing backslash is dropped.
enum IRCTagEscaping {
    static func unescape(_ value: Substring) -> String {
        guard value.contains("\\") else { return String(value) }
        var result = ""
        result.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else {
                result.append(char)
                continue
            }
            guard let next = iterator.next() else { break } // dangling backslash
            switch next {
            case ":": result.append(";")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            case "r": result.append("\r")
            case "n": result.append("\n")
            default: result.append(next)
            }
        }
        return result
    }

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for char in value {
            switch char {
            case ";": result.append("\\:")
            case " ": result.append("\\s")
            case "\\": result.append("\\\\")
            case "\r": result.append("\\r")
            case "\n": result.append("\\n")
            default: result.append(char)
            }
        }
        return result
    }
}

/// Parses and serialises the full `@tag1=v1;tag2;...` tag block (without the
/// leading `@`).
enum IRCTagBlock {
    static func parse(_ block: Substring) -> [String: String] {
        var tags: [String: String] = [:]
        for pair in block.split(separator: ";", omittingEmptySubsequences: true) {
            if let eq = pair.firstIndex(of: "=") {
                let key = String(pair[..<eq])
                let value = IRCTagEscaping.unescape(pair[pair.index(after: eq)...])
                tags[key] = value
            } else {
                tags[String(pair)] = ""
            }
        }
        return tags
    }

    static func serialize(_ tags: [String: String]) -> String {
        tags.sorted { $0.key < $1.key }
            .map { key, value in
                value.isEmpty ? key : "\(key)=\(IRCTagEscaping.escape(value))"
            }
            .joined(separator: ";")
    }
}
