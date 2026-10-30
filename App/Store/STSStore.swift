import Foundation

/// Remembered IRCv3 STS policies: hostnames that must only be reached over
/// TLS, on which port, until when. Learned from a secure connection; while
/// one is active Arkhe never connects to that host in plaintext.
enum STSStore {
    struct Policy: Codable, Equatable {
        var port: UInt16
        var duration: TimeInterval
        var expiry: Date
    }

    private static let key = "sts.policies"

    static func activePolicy(for host: String, now: Date = Date()) -> Policy? {
        guard let policy = all()[host.lowercased()], policy.expiry > now else { return nil }
        return policy
    }

    /// Stores (or, with duration 0, removes) a policy seen on a secure connection.
    static func record(host: String, port: UInt16, duration: TimeInterval, now: Date = Date()) {
        var policies = all()
        if duration <= 0 {
            policies[host.lowercased()] = nil
        } else {
            policies[host.lowercased()] = Policy(port: port, duration: duration,
                                                 expiry: now.addingTimeInterval(duration))
        }
        save(policies)
    }

    /// Pushes the expiry out by the last advertised duration — done when a
    /// secure connection closes, so long-lived connections don't let it lapse.
    static func reschedule(host: String, now: Date = Date()) {
        var policies = all()
        guard var policy = policies[host.lowercased()] else { return }
        policy.expiry = now.addingTimeInterval(policy.duration)
        policies[host.lowercased()] = policy
        save(policies)
    }

    static func remove(host: String) {
        var policies = all()
        policies[host.lowercased()] = nil
        save(policies)
    }

    private static func all() -> [String: Policy] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let policies = try? JSONDecoder().decode([String: Policy].self, from: data) else { return [:] }
        return policies
    }

    private static func save(_ policies: [String: Policy]) {
        if let data = try? JSONEncoder().encode(policies) { UserDefaults.standard.set(data, forKey: key) }
    }
}
