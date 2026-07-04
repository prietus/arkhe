import Foundation

/// Runs `work` on the main thread — synchronously if already there, otherwise
/// dispatched. UIApplication's background-task, badge and push-registration APIs
/// assert main-thread-only, but the async callbacks that reach them (SwiftUI
/// scenePhase changes, the `UNUserNotificationCenter` delegate, and background-
/// task expiration handlers) are delivered on the cooperative pool, not main.
/// Routing every such call through here makes the thread guaranteed.
func onMainThread(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
