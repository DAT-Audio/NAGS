/// What kind of thing a line in the activity log is (moved from `ActivityLog.Kind`
/// into the engine, which logs too; `ActivityLog.Kind` is this, and its colours stay with the UI).
public enum LogKind: String, Codable, CaseIterable {
    /// The user asked for something, or the app started trying to.
    case request
    /// It worked.
    case done
    /// It did not, and why.
    case failed
    /// Something ended: by the user, by the other end, or because something else changed.
    case stopped
    /// Worth knowing, needs nothing.
    case note
    /// Worth a look: it may be the start of a problem.
    case warning

    public var label: String {
        switch self {
        case .request: return "REQUEST"
        case .done:    return "DONE"
        case .failed:  return "FAILED"
        case .stopped: return "STOPPED"
        case .note:    return "NOTE"
        case .warning: return "WARNING"
        }
    }
}
