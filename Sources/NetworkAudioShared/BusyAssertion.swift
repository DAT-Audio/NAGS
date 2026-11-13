import Foundation

/// Tells macOS the app is doing time-critical work while audio flows, and stops saying so when
/// it does not.
///
/// **Why:** without it, App Nap may decide an app whose window is covered or in the background
/// is idle and coalesce its timers — the Sender's meters were seen stepping once a second after
/// ten minutes of streaming. `latencyCritical` asks for timers on time;
/// `userInitiatedAllowingIdleSystemSleep` keeps App Nap off without keeping the Mac awake.
public final class BusyAssertion {
    private var token: NSObjectProtocol?
    private let reason: String

    public init(reason: String) { self.reason = reason }

    /// Idempotent: call it as often as the state is checked.
    public func set(_ busy: Bool) {
        if busy, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: reason)
        } else if !busy, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit { set(false) }
}
