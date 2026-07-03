import Foundation
import Observation
import SwiftUI
import UIKit

/// App-wide runtime state: the live `IRCSession`s and the current UI selection.
/// Persisted `ServerConfig`s live in SwiftData and are queried by the views;
/// this store owns only the in-memory connections.
@MainActor
@Observable
final class ClientStore {
    let notifications: NotificationManager

    init(notifications: NotificationManager) {
        self.notifications = notifications
    }

    private(set) var sessions: [UUID: IRCSession] = [:]
    /// Bound soju network sessions opened under a base account config.
    private(set) var networkSessions: [UUID: [IRCSession]] = [:]
    /// "<baseConfigID>/<networkID>" → its open session, for idempotent opening.
    private var networkKeys: [String: IRCSession] = [:]

    var selectedSessionID: UUID?
    var selectedBufferID: UUID?

    var selectedSession: IRCSession? {
        selectedSessionID.flatMap { sessions[$0] }
    }

    /// All sessions belonging to a base config: the account session first, then
    /// any opened bound-network sessions.
    func allSessions(for configID: UUID) -> [IRCSession] {
        (sessions[configID].map { [$0] } ?? []) + (networkSessions[configID] ?? [])
    }

    /// Opens (or focuses) a session bound to `network` under the base bouncer
    /// account, reusing its credentials with a `/network` binding.
    func openNetwork(_ network: BouncerNetwork, from base: ServerConfig) {
        let key = "\(base.id)/\(network.id)"
        if let existing = networkKeys[key] {
            if !existing.status.isActive { existing.connect() }
            select(existing.statusBuffer, in: existing)
            return
        }
        let baseConfig = sessions[base.id]?.config ?? SessionConfig(base)
        let session = makeSession(SessionConfig(boundNetwork: network, base: baseConfig))
        sessions[session.id] = session
        networkSessions[base.id, default: []].append(session)
        networkKeys[key] = session
        session.connect()
        select(session.statusBuffer, in: session)
    }

    var selectedBuffer: Buffer? {
        guard let session = selectedSession else { return nil }
        return session.buffers.first { $0.id == selectedBufferID }
    }

    /// Returns the live session for a config, creating (but not connecting) it
    /// if needed.
    @discardableResult
    func session(for config: ServerConfig) -> IRCSession {
        if let existing = sessions[config.id] { return existing }
        let session = makeSession(SessionConfig(config))
        sessions[config.id] = session
        return session
    }

    /// Builds a session and routes its notifiable events to the app's
    /// notification layer.
    private func makeSession(_ config: SessionConfig) -> IRCSession {
        let session = IRCSession(config: config)
        session.onNotifiableEvent = { [weak self] event in
            self?.notifications.present(event)
        }
        session.onWebPushReady = { [weak self] in
            self?.notifications.registerWebPushEverywhere()
        }
        return session
    }

    func connect(_ config: ServerConfig) {
        let session = session(for: config)
        // Pick up any edits made since the session was first created — otherwise
        // a reused, offline session would reconnect to the old host/port/TLS.
        session.refreshConfig(SessionConfig(config))
        session.connect()
        selectedSessionID = config.id
        if selectedBufferID == nil {
            selectedBufferID = session.statusBuffer.id
        }
    }

    func disconnect(_ config: ServerConfig) {
        sessions[config.id]?.disconnect()
        for network in networkSessions[config.id] ?? [] { network.disconnect() }
    }

    /// Drops a session entirely (e.g. when its config is deleted), including any
    /// bound-network sessions opened under it.
    func removeSession(_ id: UUID) {
        for network in networkSessions[id] ?? [] {
            network.disconnect()
            sessions[network.id] = nil
        }
        networkSessions[id] = nil
        networkKeys = networkKeys.filter { !$0.key.hasPrefix("\(id)/") }

        sessions[id]?.disconnect()
        sessions[id] = nil
        if selectedSessionID == id {
            selectedSessionID = nil
            selectedBufferID = nil
        }
    }

    func select(_ buffer: Buffer, in session: IRCSession) {
        selectedSessionID = session.id
        selectedBufferID = buffer.id
        buffer.unreadCount = 0
        buffer.hasMention = false
    }

    // MARK: - App lifecycle

    /// Reacts to foreground/background transitions: hold the connection briefly
    /// when leaving, and reconnect + clear the badge when returning.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            beginBackgroundHold()
        case .active:
            endBackgroundHold()
            notifications.clearBadge()
            reconnectDroppedSessions()
        default:
            break
        }
    }

    /// Re-dials any session the user wanted up but that dropped while suspended.
    private func reconnectDroppedSessions() {
        for session in sessions.values { session.reconnectIfDropped() }
    }

    private var backgroundHold: UIBackgroundTaskIdentifier = .invalid

    /// Buys a short grace period after backgrounding so a message landing in the
    /// next few seconds is still processed (and can raise a local notification)
    /// before iOS suspends us and the bouncer takes over holding presence.
    private func beginBackgroundHold() {
        endBackgroundHold()
        backgroundHold = UIApplication.shared.beginBackgroundTask(withName: "im.arkhe.hold") {
            [weak self] in self?.endBackgroundHold()
        }
    }

    private func endBackgroundHold() {
        guard backgroundHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundHold)
        backgroundHold = .invalid
    }
}
