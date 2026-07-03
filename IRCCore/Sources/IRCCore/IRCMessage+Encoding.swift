import Foundation

public extension IRCMessage {
    /// Serialises the message to a single wire line, **without** the trailing
    /// CRLF (the transport appends it). Tags and source are included when set.
    ///
    /// The final parameter is rendered as a trailing parameter (`:`-prefixed)
    /// when it is empty, contains a space, or begins with `:`.
    func encoded() -> String {
        var parts: [String] = []

        if !tags.isEmpty {
            parts.append("@" + IRCTagBlock.serialize(tags))
        }
        if let source {
            parts.append(":" + source.raw)
        }
        parts.append(command)

        for (index, param) in parameters.enumerated() {
            let isLast = index == parameters.count - 1
            let needsTrailing = param.isEmpty || param.contains(" ") || param.first == ":"
            if isLast && needsTrailing {
                parts.append(":" + param)
            } else {
                parts.append(param)
            }
        }

        return parts.joined(separator: " ")
    }

    /// The full wire representation including the terminating CRLF.
    func wireData() -> Data {
        Data((encoded() + "\r\n").utf8)
    }
}
