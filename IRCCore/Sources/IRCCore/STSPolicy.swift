import Foundation

/// An IRCv3 Strict Transport Security policy, from the `sts` capability value
/// (e.g. `duration=86400,port=6697`). Each part only counts on the right kind
/// of connection: `port` (upgrade) on a plaintext one, `duration` (persist) on
/// a TLS one. Unknown keys are ignored.
public struct STSPolicy: Sendable, Equatable {
    /// Upgrade policy: reconnect securely on this port.
    public var port: UInt16?
    /// Persistence policy: connect only securely for this long; 0 removes it.
    public var duration: TimeInterval?
    public var preload: Bool

    public init(value: String?) {
        var port: UInt16?
        var duration: TimeInterval?
        var preload = false
        for token in (value ?? "").split(separator: ",") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            switch parts.first {
            case "port": port = parts.count > 1 ? UInt16(parts[1]) : nil
            case "duration": duration = parts.count > 1 ? Double(parts[1]).flatMap { $0 >= 0 ? $0 : nil } : nil
            case "preload": preload = true
            default: break
            }
        }
        self.port = port
        self.duration = duration
        self.preload = preload
    }
}
